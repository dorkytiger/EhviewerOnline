// Package scan walks the synced EhViewer tree and turns each gallery
// directory into a models.Gallery.
//
// The layout it expects is produced by AppConfig (AppConfig.java:39-135):
//
//	<root>/download/<gid>-<title>/          one directory per gallery
//	<root>/download/<gid>-<title>/.ehviewer metadata (SpiderInfo)
//	<root>/download/<gid>-<title>/00000001.jpg
//
// Nothing here ever writes to the synced tree.
package scan

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/warren/ehviewer-webd/internal/models"
	"github.com/warren/ehviewer-webd/internal/spiderinfo"
)

// imageExtensions is GalleryProvider2.SUPPORT_IMAGE_EXTENSIONS
// (GalleryProvider2.java:27-33). SpiderDen.findImageFile probes this slice in
// order and returns the first hit, so the ORDER IS MEANINGFUL: when a page
// exists as more than one file, EhViewer reads .jpg before .jpeg before .png
// and so on. We keep the same precedence.
var imageExtensions = []string{".jpg", ".jpeg", ".png", ".gif", ".webp"}

// extRank maps a lowercase extension (with dot) to its precedence.
var extRank = func() map[string]int {
	m := make(map[string]int, len(imageExtensions))
	for i, e := range imageExtensions {
		m[e] = i
	}
	return m
}()

// galleryFileName matches SpiderDen.generateImageFilename: Locale.US "%08d"
// with index+1. The extension list is the uppercase/lowercase union of
// GalleryProvider2.SUPPORT_IMAGE_EXTENSIONS; the match is case-insensitive on
// disk, and the extension is lowercased before the precedence lookup. A
// lowercase-only pattern here would silently drop 00000001.JPG.
var galleryFileName = regexp.MustCompile(`^(\d{1,8})\.([jJ][pP][eE]?[gG]|[pP][nN][gG]|[gG][iI][fF]|[wW][eE][bB][pP])$`)

// dirNamePattern matches "<gid>-<title>".
//
// The digit range is deliberately narrow (see design doc §2.4): real EH
// gallery ids are 6-9 digits, and the floor is raised to 5 specifically so
// that date-like directory names ("2024-01-01-backup", "20240101-backup" is
// still excluded by the dash requirement) are not mistaken for galleries. A
// false negative here is recoverable — the directory is reported in
// Result.Skipped — whereas a false positive puts junk in the gallery list.
var dirNamePattern = regexp.MustCompile(`^([0-9]{5,12})-(.*)$`)

// Collision suffixes appended by Syncthing.
const conflictMarker = ".sync-conflict-"

// Options tunes discovery and per-gallery loading.
type Options struct {
	// Workers bounds concurrent directory reads. Zero picks a CPU-based value.
	Workers int
	// SkipSymlinks refuses to follow symlinked gallery directories. On by
	// default; see the design doc §8.2.
	SkipSymlinks bool
	// MaxPages guards against absurd metadata. Zero uses spiderinfo.MaxPages.
	MaxPages int
}

// LoadConfig extends Options with the parsing knobs.
type LoadConfig struct {
	Options
	// MaxHeaderBytes caps .ehviewer reads. Zero uses 1 MiB.
	MaxHeaderBytes int64
}

func (o Options) workers() int {
	if o.Workers > 0 {
		return o.Workers
	}
	n := runtime.NumCPU()
	if n > 8 {
		n = 8
	}
	if n < 1 {
		n = 1
	}
	return n
}

func (o Options) maxPages() int {
	if o.MaxPages > 0 {
		return o.MaxPages
	}
	return spiderinfo.MaxPages
}

func (o LoadConfig) maxHeaderBytes() int64 {
	if o.MaxHeaderBytes > 0 {
		return o.MaxHeaderBytes
	}
	return 1 << 20
}

// Skip records a directory that looked like it might hold a gallery but was
// left out of the index.
type Skip struct {
	Path   string
	Reason string
}

// Result is everything one discovery pass produced.
type Result struct {
	Galleries []*models.Gallery
	Skipped   []Skip
	// DirCount is the number of immediate subdirectories examined.
	DirCount int
}

// Discover scans every immediate subdirectory of downloadRoot.
//
// Subdirectories are not recursed into: EhViewer stores exactly one gallery
// per directory. Directories that do not match <gid>-<title> are reported in
// Result.Skipped rather than dropped silently, which makes the "why is my
// gallery missing" question answerable.
func Discover(downloadRoot string, cfg LoadConfig) (*Result, error) {
	entries, err := os.ReadDir(downloadRoot)
	if err != nil {
		return nil, fmt.Errorf("scan: read download root %q: %w", downloadRoot, err)
	}

	res := &Result{}
	dirs := make([]string, 0, len(entries))
	for _, e := range entries {
		name := e.Name()
		if isIgnoredName(name) {
			continue
		}
		if e.Type()&fs.ModeSymlink != 0 && cfg.SkipSymlinks {
			res.Skipped = append(res.Skipped, Skip{
				Path:   filepath.Join(downloadRoot, name),
				Reason: "symlink",
			})
			continue
		}
		if !e.IsDir() {
			continue
		}
		if IsConflictedName(name) {
			res.Skipped = append(res.Skipped, Skip{
				Path:   filepath.Join(downloadRoot, name),
				Reason: "syncthing conflict copy",
			})
			continue
		}
		res.DirCount++
		if !dirNamePattern.MatchString(name) {
			res.Skipped = append(res.Skipped, Skip{
				Path:   filepath.Join(downloadRoot, name),
				Reason: "directory name is not <gid>-<title>",
			})
			continue
		}
		dirs = append(dirs, filepath.Join(downloadRoot, name))
	}

	sort.Strings(dirs)
	res.Galleries = loadAll(dirs, cfg)

	return res, nil
}

func loadAll(dirs []string, cfg LoadConfig) []*models.Gallery {
	workers := cfg.Options.workers()
	if workers > len(dirs) {
		workers = len(dirs)
	}
	if workers == 0 {
		return nil
	}

	out := make([]*models.Gallery, len(dirs))
	next := make(chan int, workers)
	var wg sync.WaitGroup

	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range next {
				g, err := LoadDir(dirs[i], cfg)
				if err != nil || g == nil {
					// A single unreadable directory must not sink the scan;
					// it is recorded as a placeholder so the operator can see it.
					out[i] = unreadableGallery(dirs[i], err)
					continue
				}
				out[i] = g
			}
		}()
	}
	for i := range dirs {
		next <- i
	}
	close(next)
	wg.Wait()

	kept := out[:0]
	for _, g := range out {
		if g != nil {
			kept = append(kept, g)
		}
	}
	return kept
}

func unreadableGallery(dir string, cause error) *models.Gallery {
	name := filepath.Base(dir)
	gid, rawTitle, _ := ParseDirName(name)
	reason := "unreadable_directory"
	if cause != nil {
		reason = reason + ": " + cause.Error()
	}
	return &models.Gallery{
		GID:          gid,
		Title:        rawTitle,
		TitleSource:  models.TitleSourceDirname,
		DirPath:      dir,
		DirName:      name,
		Availability: models.AvailMissing,
		MetaSource:   models.MetaSourceLocalOnly,
		Anomalies:    []string{reason},
	}
}

// ParseDirName splits "<gid>-<title>". ok is false when the name does not
// match, in which case gid is 0 and title is the name unchanged.
//
// The title is only ever a fallback: FileUtils.sanitizeFilename has already
// mangled it and its exact rules live in a dependency (see design doc §2.4),
// so a DB snapshot always wins.
func ParseDirName(name string) (gid int64, title string, ok bool) {
	m := dirNamePattern.FindStringSubmatch(name)
	if m == nil {
		return 0, name, false
	}
	v, err := strconv.ParseInt(m[1], 10, 64)
	if err != nil {
		return 0, name, false
	}
	return v, m[2], true
}

// IsIgnoredName reports whether a directory entry is Syncthing/EhViewer
// bookkeeping rather than gallery content.
func IsIgnoredName(name string) bool { return isIgnoredName(name) }

func isIgnoredName(name string) bool {
	// Syncthing artifacts.
	if name == ".stfolder" || name == ".stversions" || name == ".stignore" ||
		name == ".DS_Store" {
		return true
	}
	// Syncthing writes "~syncthing~<name>.tmp" while transferring.
	if strings.HasPrefix(name, "~syncthing~") {
		return true
	}
	if strings.HasSuffix(name, ".tmp") {
		return true
	}
	return false
}

// IsConflictedName reports whether a name is a Syncthing conflict copy.
// Such directories are skipped: they are usually stale duplicates.
func IsConflictedName(name string) bool {
	return strings.Contains(name, conflictMarker)
}

// LoadDir reads one gallery directory.
func LoadDir(dir string, cfg LoadConfig) (*models.Gallery, error) {
	dirName := filepath.Base(dir)
	gid, rawTitle, nameOK := ParseDirName(dirName)

	g := &models.Gallery{
		GID:          gid,
		Title:        rawTitle,
		TitleSource:  models.TitleSourceDirname,
		DirPath:      dir,
		DirName:      dirName,
		Availability: models.AvailOK,
		MetaSource:   models.MetaSourceLocalOnly,
	}
	if !nameOK {
		g.Anomalies = append(g.Anomalies, models.AnomalyDirUnparsable)
	}

	// .ehviewer: authoritative for gid/token/pages when present.
	infoPath := filepath.Join(dir, spiderinfo.FileName)
	if raw, err := readSmallFile(infoPath, cfg.maxHeaderBytes()); err == nil {
		info, perr := spiderinfo.Parse(strings.NewReader(raw))
		if perr != nil {
			g.Anomalies = append(g.Anomalies, models.AnomalySpiderInfoInvalid)
		} else {
			if nameOK && info.GID != gid {
				g.Anomalies = append(g.Anomalies, models.AnomalyGIDMismatch)
			}
			g.GID = info.GID
			g.Token = info.Token
			g.PagesExpected = info.Pages
			g.Spider = info
		}
	} else if errors.Is(err, os.ErrNotExist) {
		// Missing metadata is not fatal — the gallery stays browsable using the
		// gid from the directory name and the pages found on disk — but it is
		// reported so the client can show that the entry is incomplete rather
		// than silently presenting it as fully described.
		g.Anomalies = append(g.Anomalies, models.AnomalySpiderInfoMissing)
	} else {
		g.Anomalies = append(g.Anomalies, models.AnomalySpiderInfoInvalid)
	}

	pages, total, maxMTime, err := collectPages(dir, g.GID)
	if err != nil {
		return nil, err
	}
	g.Pages = pages
	g.PagesFound = len(pages)
	g.TotalBytes = total
	g.MaxMTimeMS = maxMTime

	g.Anomalies = append(g.Anomalies, consistencyAnomalies(pages, g.PagesExpected)...)
	g.Availability = availabilityOf(g)
	g.CoverKind, g.CoverURL = coverPlaceholder(g)

	return g, nil
}

// collectPages lists the image files in dir and returns them in page order.
func collectPages(dir string, gid int64) ([]models.Page, int64, int64, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, 0, 0, err
	}

	type candidate struct {
		ext   string
		name  string
		size  int64
		mtime int64
	}
	byIndex := make(map[int]candidate, len(entries))

	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if isIgnoredName(name) || IsConflictedName(name) {
			continue
		}
		m := galleryFileName.FindStringSubmatch(name)
		if m == nil {
			continue
		}
		ext := strings.ToLower(filepath.Ext(name))
		rank, known := extRank[ext]
		if !known {
			continue
		}
		n, err := strconv.Atoi(m[1])
		if err != nil || n < 1 {
			continue
		}
		index := n - 1

		fi, err := e.Info()
		var size, mtime int64
		if err == nil {
			size = fi.Size()
			mtime = fi.ModTime().UnixMilli()
		}

		prev, exists := byIndex[index]
		if !exists || rank < extRank[prev.ext] {
			byIndex[index] = candidate{ext: ext, name: name, size: size, mtime: mtime}
		}
	}

	indexes := make([]int, 0, len(byIndex))
	for i := range byIndex {
		indexes = append(indexes, i)
	}
	sort.Ints(indexes)

	pages := make([]models.Page, 0, len(indexes))
	var total, maxMTime int64
	for _, i := range indexes {
		c := byIndex[i]
		pages = append(pages, models.Page{
			Index:    i,
			Filename: c.name,
			Ext:      c.ext,
			Size:     c.size,
			MTimeMS:  c.mtime,
			URL:      fmt.Sprintf("/img/%d/%d", gid, i),
		})
		total += c.size
		if c.mtime > maxMTime {
			maxMTime = c.mtime
		}
	}
	return pages, total, maxMTime, nil
}

// consistencyAnomalies compares what .ehviewer claims against what is on disk.
// Disk always wins; PagesExpected is advisory (design doc §2.3).
func consistencyAnomalies(pages []models.Page, expected int) []string {
	var out []string
	if len(pages) == 0 {
		return append(out, models.AnomalyEmptyGallery)
	}
	if expected > 0 && len(pages) != expected {
		out = append(out, models.AnomalyPageCountMismatch)
	}
	for i, p := range pages {
		if p.Index != i {
			out = append(out, models.AnomalyPageGap)
			break
		}
	}
	return out
}

func availabilityOf(g *models.Gallery) models.Availability {
	if g.PagesFound == 0 {
		return models.AvailMissing
	}
	if len(g.Anomalies) > 0 {
		return models.AvailDegraded
	}
	return models.AvailOK
}

// coverPlaceholder points the cover at the first page. The HTTP layer may
// substitute an image-cache thumbnail when one is available; see thumbcache.
func coverPlaceholder(g *models.Gallery) (kind, url string) {
	if len(g.Pages) == 0 {
		return "none", ""
	}
	v := g.MaxMTimeMS
	if v == 0 {
		v = time.Now().UnixMilli()
	}
	return "firstpage", fmt.Sprintf("/thumb/%d?v=%d", g.GID, v)
}

func readSmallFile(path string, limit int64) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()

	// Read one byte past the limit so an oversized file is detected rather
	// than silently truncated.
	buf, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil {
		return "", err
	}
	if int64(len(buf)) > limit {
		return "", fmt.Errorf("scan: %s exceeds %d bytes", path, limit)
	}
	return string(buf), nil
}
