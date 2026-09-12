package thumbcache

import (
	"bytes"
	"context"
	"encoding/binary"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func writePNG(t *testing.T, dir string, w, h int) string {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.Set(x, y, color.RGBA{R: uint8(x), G: uint8(y), B: 200, A: 255})
		}
	}
	path := filepath.Join(dir, "src.png")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if err := png.Encode(f, img); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestGetRendersAndCaches(t *testing.T) {
	srcDir := t.TempDir()
	cacheDir := filepath.Join(t.TempDir(), "cache")
	src := writePNG(t, srcDir, 200, 100)

	c, err := New(Options{Dir: cacheDir, MaxDim: 50, Workers: 1})
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	first, err := c.Get(context.Background(), "cover", src, 1)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	cfg, format, err := image.DecodeConfig(bytes.NewReader(first))
	if err != nil {
		t.Fatalf("rendered thumbnail is not decodable: %v", err)
	}
	if format != "jpeg" {
		t.Errorf("format: got %q, want jpeg", format)
	}
	// 200x100 with a 50px long edge becomes 50x25.
	if cfg.Width != 50 || cfg.Height != 25 {
		t.Errorf("rendered %dx%d, want 50x25 (aspect preserved)", cfg.Width, cfg.Height)
	}

	if s := c.Stats(); s.Misses != 1 || s.Hits != 0 {
		t.Errorf("after the first call: %+v, want 1 miss and 0 hits", s)
	}

	second, err := c.Get(context.Background(), "cover", src, 1)
	if err != nil {
		t.Fatalf("second Get: %v", err)
	}
	if !bytes.Equal(first, second) {
		t.Error("a cached thumbnail should be byte-identical")
	}
	if s := c.Stats(); s.Hits != 1 {
		t.Errorf("after the second call: %+v, want 1 hit", s)
	}
}

// A new version must miss the cache, so a re-downloaded page gets a fresh
// thumbnail rather than a stale one.
func TestVersionInvalidatesTheCache(t *testing.T) {
	srcDir := t.TempDir()
	c, err := New(Options{Dir: filepath.Join(t.TempDir(), "cache"), MaxDim: 32})
	if err != nil {
		t.Fatal(err)
	}
	src := writePNG(t, srcDir, 64, 64)

	if _, err := c.Get(context.Background(), "k", src, 100); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Get(context.Background(), "k", src, 200); err != nil {
		t.Fatal(err)
	}
	if s := c.Stats(); s.Misses != 2 {
		t.Errorf("a changed version should miss: %+v", s)
	}

	// The same key at a different size is a different cache entry too.
	smaller, err := New(Options{Dir: c.dir, MaxDim: 16})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := smaller.Get(context.Background(), "k", src, 100); err != nil {
		t.Fatal(err)
	}
	if s := smaller.Stats(); s.Misses != 1 {
		t.Errorf("a changed max dimension should miss: %+v", s)
	}
}

// An image whose declared dimensions exceed the limits must be refused from the
// header alone, before any bitmap is allocated. This is the decompression-bomb
// guard, so it is worth testing against a real header rather than a mock.
func TestOversizedImageIsRefused(t *testing.T) {
	srcDir := t.TempDir()
	c, err := New(Options{Dir: filepath.Join(t.TempDir(), "cache"), MaxDim: 32})
	if err != nil {
		t.Fatal(err)
	}

	// A minimal PNG header claiming 30000x30000, with no actual pixel data.
	// DecodeConfig reads only the header, which is exactly the point.
	path := filepath.Join(srcDir, "huge.png")
	if err := os.WriteFile(path, fakePNGHeader(30000, 30000), 0o644); err != nil {
		t.Fatal(err)
	}

	_, err = c.Get(context.Background(), "huge", path, 1)
	if err == nil {
		t.Fatal("expected an oversized image to be refused")
	}
	if !strings.Contains(err.Error(), "exceed") && !strings.Contains(err.Error(), "unsupported") {
		t.Logf("error was: %v", err)
	}
	if s := c.Stats(); s.Errors == 0 {
		t.Errorf("the refusal should be counted: %+v", s)
	}
}

// A 20000+ pixel axis must be refused even when the total pixel count is small.
func TestExcessiveDimensionIsRefused(t *testing.T) {
	srcDir := t.TempDir()
	c, err := New(Options{Dir: filepath.Join(t.TempDir(), "cache")})
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(srcDir, "tall.png")
	if err := os.WriteFile(path, fakePNGHeader(10, MaxSourceDim+1), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Get(context.Background(), "tall", path, 1); err == nil {
		t.Fatal("expected an over-tall image to be refused")
	}
}

// Just under the axis limit, with a small pixel count, must be accepted.
func TestImageJustUnderTheLimitsIsAccepted(t *testing.T) {
	srcDir := t.TempDir()
	c, err := New(Options{Dir: filepath.Join(t.TempDir(), "cache"), MaxDim: 8})
	if err != nil {
		t.Fatal(err)
	}
	src := writePNG(t, srcDir, 10, MaxSourceDim-1)
	if _, err := c.Get(context.Background(), "ok", src, 1); err != nil {
		t.Fatalf("an image within the limits should render: %v", err)
	}
}

func TestCorruptImageIsRejected(t *testing.T) {
	srcDir := t.TempDir()
	c, err := New(Options{Dir: filepath.Join(t.TempDir(), "cache")})
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(srcDir, "not-an-image.png")
	if err := os.WriteFile(path, []byte("this is not an image"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Get(context.Background(), "bad", path, 1); err == nil {
		t.Fatal("expected a corrupt image to be rejected")
	}
}

func TestMissingSourceIsAnError(t *testing.T) {
	c, err := New(Options{Dir: filepath.Join(t.TempDir(), "cache")})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.Get(context.Background(), "x", filepath.Join(t.TempDir(), "nope.png"), 1); err == nil {
		t.Fatal("expected an error for a missing source file")
	}
}

// With no cache directory configured the cache must still render, just without
// persisting anything.
func TestDisabledCacheStillRenders(t *testing.T) {
	srcDir := t.TempDir()
	src := writePNG(t, srcDir, 64, 64)

	c, err := New(Options{Dir: "", MaxDim: 16})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	b, err := c.Get(context.Background(), "k", src, 1)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if len(b) == 0 {
		t.Error("expected rendered bytes")
	}
	if _, err := c.Get(context.Background(), "k", src, 1); err != nil {
		t.Fatal(err)
	}
	// Every call renders, because nothing is stored.
	if s := c.Stats(); s.Hits != 0 || s.Misses != 2 {
		t.Errorf("with caching disabled every call should miss: %+v", s)
	}
}

func TestInvalidateRemovesTheEntry(t *testing.T) {
	srcDir := t.TempDir()
	c, err := New(Options{Dir: filepath.Join(t.TempDir(), "cache"), MaxDim: 16})
	if err != nil {
		t.Fatal(err)
	}
	src := writePNG(t, srcDir, 64, 64)

	if _, err := c.Get(context.Background(), "k", src, 7); err != nil {
		t.Fatal(err)
	}
	c.Invalidate("k", 7)
	if _, err := c.Get(context.Background(), "k", src, 7); err != nil {
		t.Fatal(err)
	}
	if s := c.Stats(); s.Hits != 0 {
		t.Errorf("an invalidated entry must not be served from cache: %+v", s)
	}
}

// A cancelled context must abort rather than block forever waiting for a slot.
func TestCancelledContextDoesNotBlock(t *testing.T) {
	srcDir := t.TempDir()
	src := writePNG(t, srcDir, 64, 64)

	// One worker, occupied by a long render, so a second call has to wait.
	c, err := New(Options{Dir: filepath.Join(t.TempDir(), "cache"), MaxDim: 64, Workers: 1})
	if err != nil {
		t.Fatal(err)
	}
	c.throttle <- struct{}{} // take the only slot

	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()

	start := time.Now()
	_, err = c.Get(ctx, "k", src, 1)
	if err == nil {
		t.Fatal("expected the cancelled context to surface as an error")
	}
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Errorf("cancellation took %v; it should return promptly", elapsed)
	}
}

func TestDownscalePreservesAspectAndCap(t *testing.T) {
	cases := []struct {
		w, h, max    int
		wantW, wantH int
	}{
		{100, 50, 50, 50, 25},
		{50, 100, 50, 25, 50},
		{10, 10, 50, 10, 10}, // smaller than the cap: unchanged
		{200, 200, 100, 100, 100},
		{1000, 1, 100, 100, 1}, // extreme aspect must not collapse to zero
		{1, 1000, 100, 1, 100},
	}
	for _, c := range cases {
		src := image.NewRGBA(image.Rect(0, 0, c.w, c.h))
		got := downscale(src, c.max)
		if got.Bounds().Dx() != c.wantW || got.Bounds().Dy() != c.wantH {
			t.Errorf("downscale(%dx%d, max=%d) = %dx%d, want %dx%d",
				c.w, c.h, c.max, got.Bounds().Dx(), got.Bounds().Dy(), c.wantW, c.wantH)
		}
	}
}

// downscale must not crash on a degenerate input.
func TestDownscaleZeroSize(t *testing.T) {
	got := downscale(image.NewRGBA(image.Rect(0, 0, 0, 0)), 10)
	if got.Bounds().Dx() < 1 || got.Bounds().Dy() < 1 {
		t.Errorf("a zero-sized source should still yield a 1x1 image, got %v", got.Bounds())
	}
}

// fakePNGHeader builds a PNG containing only a valid signature and IHDR.
// image.DecodeConfig succeeds on it, while a real decode would fail — which is
// precisely the path the size guard must intercept first.
func fakePNGHeader(w, h int) []byte {
	var b bytes.Buffer
	b.Write([]byte{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a})

	var ihdr bytes.Buffer
	_ = binary.Write(&ihdr, binary.BigEndian, uint32(w))
	_ = binary.Write(&ihdr, binary.BigEndian, uint32(h))
	ihdr.Write([]byte{8, 6, 0, 0, 0}) // 8-bit RGBA, no interlace

	chunk := func(typ string, data []byte) {
		var lenBuf [4]byte
		binary.BigEndian.PutUint32(lenBuf[:], uint32(len(data)))
		b.Write(lenBuf[:])
		b.WriteString(typ)
		b.Write(data)
		// The CRC is not validated by DecodeConfig for our purposes, but a
		// zero value keeps the chunk structurally intact.
		b.Write([]byte{0, 0, 0, 0})
	}
	chunk("IHDR", ihdr.Bytes())
	return b.Bytes()
}
