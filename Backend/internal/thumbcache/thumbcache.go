// Package thumbcache renders and caches gallery cover thumbnails.
//
// Two things make this necessary rather than optional:
//
//   - The gallery list shows one cover per row. Serving original pages there
//     would push tens of megabytes per screenful through the frp tunnel twice
//     (see the design doc R14), so covers must be downscaled on the server.
//   - Decoding an arbitrary user-supplied image is a decompression-bomb risk.
//     image.DecodeConfig is called first and anything oversized is refused
//     without ever allocating the full bitmap (design doc §8.2, R8).
//
// The cache lives under the service's own data directory, never inside the
// synced tree.
package thumbcache

import (
	"bytes"
	"context"
	"crypto/md5"
	"encoding/hex"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/jpeg"
	"io"
	"os"
	"path/filepath"
	"sync/atomic"

	// Registered decoders. image/jpeg, image/png and image/gif come from the
	// standard library; webp needs golang.org/x/image.
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"

	_ "golang.org/x/image/webp"
)

// Limits guarding the decode path.
const (
	// MaxSourcePixels refuses anything larger than this before decoding.
	// 8000x8000 = 64 MP is well above any real doujin page and still small
	// enough that a decode cannot exhaust memory.
	MaxSourcePixels = 64_000_000
	// MaxSourceDim caps either axis.
	MaxSourceDim = 20000
	// DefaultMaxDim is the long-edge size of a rendered thumbnail.
	DefaultMaxDim = 480
	// DefaultQuality is the JPEG/WebP encoder quality.
	DefaultQuality = 82
)

// ErrTooLarge is returned when the source image exceeds the decode limits.
var ErrTooLarge = errors.New("thumbcache: source image exceeds the decode limits")

// Cache renders and stores thumbnails.
type Cache struct {
	dir      string
	maxDim   int
	quality  int
	throttle chan struct{}

	hits   atomic.Int64
	misses atomic.Int64
	errors atomic.Int64
}

// Options configures a Cache.
type Options struct {
	// Dir is the writable cache directory. Created on demand.
	Dir string
	// MaxDim is the long-edge target size. Zero uses DefaultMaxDim.
	MaxDim int
	// Quality is the encoder quality. Zero uses DefaultQuality.
	Quality int
	// Workers caps concurrent renders. Zero uses 2.
	Workers int
}

// New creates a cache. Dir must be writable; an empty Dir disables caching
// and makes Get render on every call.
func New(opts Options) (*Cache, error) {
	if opts.MaxDim <= 0 {
		opts.MaxDim = DefaultMaxDim
	}
	if opts.Quality <= 0 {
		opts.Quality = DefaultQuality
	}
	if opts.Workers <= 0 {
		opts.Workers = 2
	}
	c := &Cache{
		dir:      opts.Dir,
		maxDim:   opts.MaxDim,
		quality:  opts.Quality,
		throttle: make(chan struct{}, opts.Workers),
	}
	if c.dir != "" {
		if err := os.MkdirAll(c.dir, 0o755); err != nil {
			return nil, fmt.Errorf("thumbcache: create cache dir: %w", err)
		}
	}
	return c, nil
}

// Stats reports cache counters.
type Stats struct {
	Hits   int64 `json:"hits"`
	Misses int64 `json:"misses"`
	Errors int64 `json:"errors"`
}

// Stats returns a snapshot of the counters.
func (c *Cache) Stats() Stats {
	return Stats{Hits: c.hits.Load(), Misses: c.misses.Load(), Errors: c.errors.Load()}
}

// pathFor returns the cache path. A two-level fan-out keeps any single
// directory small, which matters on filesystems with slow readdir.
func (c *Cache) pathFor(key string) string {
	sum := md5.Sum([]byte(key))
	h := hex.EncodeToString(sum[:])
	return filepath.Join(c.dir, h[:2], h[2:4], h+".jpg")
}

// Get returns a rendered thumbnail for key, rendering it from srcPath on a
// cache miss. version is folded into the cache key so a re-downloaded page
// invalidates the thumbnail.
//
// The returned bytes are always JPEG.
func (c *Cache) Get(ctx context.Context, key, srcPath string, version int64) ([]byte, error) {
	if c.dir == "" {
		c.misses.Add(1)
		return c.render(srcPath)
	}
	cacheKey := fmt.Sprintf("%s:%d:%d", key, version, c.maxDim)
	path := c.pathFor(cacheKey)

	if b, err := os.ReadFile(path); err == nil && len(b) > 0 {
		c.hits.Add(1)
		return b, nil
	}
	c.misses.Add(1)

	// Bound concurrent renders. A caller that cannot acquire a slot within the
	// context deadline gets a clear error rather than piling up.
	select {
	case c.throttle <- struct{}{}:
		defer func() { <-c.throttle }()
	case <-ctx.Done():
		return nil, ctx.Err()
	}

	// Another request may have produced it while we waited.
	if b, err := os.ReadFile(path); err == nil && len(b) > 0 {
		c.hits.Add(1)
		return b, nil
	}

	b, err := c.render(srcPath)
	if err != nil {
		c.errors.Add(1)
		return nil, err
	}

	// Write to a temp file and rename so a concurrent reader never sees a
	// partial thumbnail.
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return b, nil // still serve the bytes we rendered
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".tmp-thumb-*")
	if err != nil {
		return b, nil
	}
	tmpName := tmp.Name()
	_, werr := tmp.Write(b)
	cerr := tmp.Close()
	if werr != nil || cerr != nil {
		os.Remove(tmpName)
		return b, nil
	}
	if err := os.Rename(tmpName, path); err != nil {
		os.Remove(tmpName)
	}
	return b, nil
}

// Invalidate drops the cached thumbnail for key, if any.
func (c *Cache) Invalidate(key string, version int64) {
	if c.dir == "" {
		return
	}
	os.Remove(c.pathFor(fmt.Sprintf("%s:%d:%d", key, version, c.maxDim)))
}

// render decodes srcPath, downscales it and encodes JPEG.
func (c *Cache) render(srcPath string) ([]byte, error) {
	f, err := os.Open(srcPath)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	// First pass: header only. This is the decompression-bomb guard.
	cfg, format, err := image.DecodeConfig(f)
	if err != nil {
		return nil, fmt.Errorf("thumbcache: unsupported or corrupt image: %w", err)
	}
	if cfg.Width <= 0 || cfg.Height <= 0 {
		return nil, fmt.Errorf("thumbcache: image reports a zero dimension")
	}
	if cfg.Width > MaxSourceDim || cfg.Height > MaxSourceDim ||
		int64(cfg.Width)*int64(cfg.Height) > MaxSourcePixels {
		return nil, fmt.Errorf("%w: %dx%d %s", ErrTooLarge, cfg.Width, cfg.Height, format)
	}

	// Second pass: real decode.
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		return nil, err
	}
	src, _, err := image.Decode(f)
	if err != nil {
		return nil, fmt.Errorf("thumbcache: decode: %w", err)
	}

	dst := downscale(src, c.maxDim)

	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, dst, &jpeg.Options{Quality: c.quality}); err != nil {
		return nil, fmt.Errorf("thumbcache: encode: %w", err)
	}
	return buf.Bytes(), nil
}

// downscale resizes src so its long edge is at most maxDim, using a box filter.
//
// A box filter is the right choice here: covers are being shrunk by roughly an
// order of magnitude, where a box filter's mild aliasing is invisible, and it
// avoids a resampling dependency. Nearest-neighbour would alias badly on the
// fine line art typical of these images.
func downscale(src image.Image, maxDim int) *image.RGBA {
	b := src.Bounds()
	sw, sh := b.Dx(), b.Dy()
	if sw <= 0 || sh <= 0 {
		return image.NewRGBA(image.Rect(0, 0, 1, 1))
	}

	dw, dh := sw, sh
	if sw > maxDim || sh > maxDim {
		if sw >= sh {
			dw = maxDim
			dh = max(1, sh*maxDim/sw)
		} else {
			dh = maxDim
			dw = max(1, sw*maxDim/sh)
		}
	}

	dst := image.NewRGBA(image.Rect(0, 0, dw, dh))
	if dw == sw && dh == sh {
		// Fast path: straight copy, no resampling.
		for y := 0; y < sh; y++ {
			for x := 0; x < sw; x++ {
				dst.Set(x, y, src.At(b.Min.X+x, b.Min.Y+y))
			}
		}
		return dst
	}

	for dy := 0; dy < dh; dy++ {
		y0 := b.Min.Y + dy*sh/dh
		y1 := b.Min.Y + (dy+1)*sh/dh
		if y1 <= y0 {
			y1 = y0 + 1
		}
		if y1 > b.Max.Y {
			y1 = b.Max.Y
		}
		for dx := 0; dx < dw; dx++ {
			x0 := b.Min.X + dx*sw/dw
			x1 := b.Min.X + (dx+1)*sw/dw
			if x1 <= x0 {
				x1 = x0 + 1
			}
			if x1 > b.Max.X {
				x1 = b.Max.X
			}

			var r, g, bl, a, n uint64
			for y := y0; y < y1; y++ {
				for x := x0; x < x1; x++ {
					cr, cg, cb, ca := src.At(x, y).RGBA()
					// RGBA returns 16-bit values; keep them there and divide
					// once at the end to avoid compounding rounding error.
					r += uint64(cr)
					g += uint64(cg)
					bl += uint64(cb)
					a += uint64(ca)
					n++
				}
			}
			if n == 0 {
				continue
			}
			// Convert back to 8-bit per channel.
			dst.SetRGBA(dx, dy, color.RGBA{
				R: uint8(r / n >> 8),
				G: uint8(g / n >> 8),
				B: uint8(bl / n >> 8),
				A: uint8(a / n >> 8),
			})
		}
	}
	return dst
}
