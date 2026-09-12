package scan

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/warren/ehviewer-webd/internal/models"
	"github.com/warren/ehviewer-webd/internal/spiderinfo"
)

// ---------------------------------------------------------------------------
// Synthetic synced-tree builder
//
// The layout mirrors what EhViewer writes; see AppConfig.java:39-135 and
// SpiderDen.generateImageFilename.
// ---------------------------------------------------------------------------

type tree struct {
	t    *testing.T
	root string
}

func newTree(t *testing.T) *tree {
	t.Helper()
	return &tree{t: t, root: t.TempDir()}
}

// galleryDir creates <root>/download/<name> and returns its path.
func (tr *tree) galleryDir(name string) string {
	tr.t.Helper()
	dir := filepath.Join(tr.root, "download", name)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		tr.t.Fatalf("mkdir %s: %v", dir, err)
	}
	return dir
}

// downloadRoot returns <root>/download.
func (tr *tree) downloadRoot() string {
	return filepath.Join(tr.root, "download")
}

// pages writes n image files named 00000001..0000000n with the given ext.
func (tr *tree) pages(dir string, n int, ext string) {
	tr.t.Helper()
	for i := 1; i <= n; i++ {
		name := formatPageName(i, ext)
		if err := os.WriteFile(filepath.Join(dir, name), []byte("fake image payload"), 0o644); err != nil {
			tr.t.Fatalf("write page %s: %v", name, err)
		}
	}
}

// page writes a single page file with an explicit index and extension.
func (tr *tree) page(dir string, index int, ext string) {
	tr.t.Helper()
	name := formatPageName(index, ext)
	if err := os.WriteFile(filepath.Join(dir, name), []byte("x"), 0o644); err != nil {
		tr.t.Fatalf("write page %s: %v", name, err)
	}
}

// spiderInfo writes .ehviewer using the real serializer, so the fixture can
// never disagree with the format the parser expects.
func (tr *tree) spiderInfo(dir string, version int, gid int64, token string, pages int) {
	tr.t.Helper()
	text, err := spiderinfo.Format(models.SpiderInfo{
		Version:        version,
		GID:            gid,
		Token:          token,
		PreviewPages:   1,
		PreviewPerPage: 20,
		Pages:          pages,
	})
	if err != nil {
		tr.t.Fatalf("Format: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, spiderinfo.FileName), []byte(text), 0o644); err != nil {
		tr.t.Fatalf("write .ehviewer: %v", err)
	}
}

func (tr *tree) file(dir, name, content string) {
	tr.t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
		tr.t.Fatalf("write %s: %v", name, err)
	}
}

func formatPageName(index int, ext string) string {
	// SpiderDen.generateImageFilename: "%08d" with index+1.
	return pad8(index) + ext
}

func pad8(n int) string {
	s := ""
	for i := 0; i < 8-len(itoa(n)); i++ {
		s += "0"
	}
	return s + itoa(n)
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}

func find(t *testing.T, res *Result, gid int64) *models.Gallery {
	t.Helper()
	for _, g := range res.Galleries {
		if g.GID == gid {
			return g
		}
	}
	t.Fatalf("gid %d not found in result (%d galleries)", gid, len(res.Galleries))
	return nil
}

func hasAnomaly(g *models.Gallery, code string) bool {
	for _, a := range g.Anomalies {
		if a == code {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Happy path
// ---------------------------------------------------------------------------

func TestDiscoverHappyPath(t *testing.T) {
	tr := newTree(t)
	dir := tr.galleryDir("1234567-My Gallery")
	tr.pages(dir, 5, ".jpg")
	tr.spiderInfo(dir, 2, 1234567, "deadbeef", 5)

	res, err := Discover(tr.downloadRoot(), LoadConfig{})
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	if len(res.Galleries) != 1 {
		t.Fatalf("got %d galleries, want 1", len(res.Galleries))
	}
	g := find(t, res, 1234567)

	if g.Title != "My Gallery" {
		t.Errorf("title: got %q, want %q", g.Title, "My Gallery")
	}
	if g.TitleSource != models.TitleSourceDirname {
		t.Errorf("title source: got %q", g.TitleSource)
	}
	if g.Token != "deadbeef" {
		t.Errorf("token: got %q", g.Token)
	}
	if g.PagesExpected != 5 || g.PagesFound != 5 {
		t.Errorf("pages: expected=%d found=%d, want 5 and 5", g.PagesExpected, g.PagesFound)
	}
	if g.Availability != models.AvailOK {
		t.Errorf("availability: got %q, want %q (anomalies: %v)", g.Availability, models.AvailOK, g.Anomalies)
	}
	if len(g.Anomalies) != 0 {
		t.Errorf("unexpected anomalies: %v", g.Anomalies)
	}
	if g.TotalBytes == 0 {
		t.Error("total bytes should be non-zero")
	}
	if len(g.Pages) != 5 {
		t.Fatalf("pages slice: got %d", len(g.Pages))
	}
	// Page URLs and 0-based indexes.
	if g.Pages[0].Index != 0 || g.Pages[0].Filename != "00000001.jpg" {
		t.Errorf("first page: %+v", g.Pages[0])
	}
	if g.Pages[0].URL != "/img/1234567/0" {
		t.Errorf("first page url: got %q", g.Pages[0].URL)
	}
	if g.Pages[4].Index != 4 || g.Pages[4].URL != "/img/1234567/4" {
		t.Errorf("last page: %+v", g.Pages[4])
	}
	if g.CoverURL == "" {
		t.Error("cover url should be set")
	}
}

// ---------------------------------------------------------------------------
// Extension precedence
// ---------------------------------------------------------------------------

// SpiderDen.findImageFile iterates SUPPORT_IMAGE_EXTENSIONS in declaration
// order (.jpg, .jpeg, .png, .gif, .webp) and returns the first hit. When a page
// exists as several files, the EARLIEST extension in that array wins - not the
// alphabetically first, and not the longest match. ".jpeg" sorts before ".jpg"
// alphabetically, so this case catches a naive implementation.
func TestExtensionPrecedence(t *testing.T) {
	tr := newTree(t)
	dir := tr.galleryDir("10000-Multi")
	tr.page(dir, 1, ".jpg")
	tr.page(dir, 1, ".png")
	tr.page(dir, 1, ".webp")

	res, err := Discover(tr.downloadRoot(), LoadConfig{})
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	g := find(t, res, 10000)
	if len(g.Pages) != 1 {
		t.Fatalf("got %d pages, want 1 (one index, several extensions)", len(g.Pages))
	}
	if g.Pages[0].Filename != "00000001.jpg" {
		t.Errorf("expected .jpg to win (first in SUPPORT_IMAGE_EXTENSIONS), got %q",
			g.Pages[0].Filename)
	}
}

// The same rule with the pair that breaks a lexicographic comparison.
func TestExtensionPrecedenceJpegBeforeJpgAlphabetically(t *testing.T) {
	tr := newTree(t)
	dir := tr.galleryDir("10001-JpegVsJpg")
	// ".jpeg" < ".jpg" as strings, but ".jpg" comes first in the array.
	tr.page(dir, 1, ".jpeg")
	tr.page(dir, 1, ".jpg")

	res, err := Discover(tr.downloadRoot(), LoadConfig{})
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	g := find(t, res, 10001)
	if g.Pages[0].Filename != "00000001.jpg" {
		t.Errorf("got %q, want 00000001.jpg (.jpg precedes .jpeg in the array)",
			g.Pages[0].Filename)
	}
}

// Only the five supported extensions count. .bmp is NOT in
// SUPPORT_IMAGE_EXTENSIONS, so a lone .bmp must not become a page.
func TestUnsupportedExtensionsIgnored(t *testing.T) {
	tr := newTree(t)
	dir := tr.galleryDir("10002-Bmp")
	tr.page(dir, 1, ".bmp")
	tr.page(dir, 2, ".png")
	tr.file(dir, "cover.png", "not a numbered page")
	tr.file(dir, "notes.txt", "hello")

	res, err := Discover(tr.downloadRoot(), LoadConfig{})
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	g := find(t, res, 10002)
	if len(g.Pages) != 1 {
		t.Fatalf("got %d pages, want only the .png one: %+v", len(g.Pages), g.Pages)
	}
	if g.Pages[0].Filename != "00000002.png" {
		t.Errorf("got %q", g.Pages[0].Filename)
	}
	// A single page at index 1 leaves a gap at 0.
	if !hasAnomaly(g, models.AnomalyPageGap) {
		t.Errorf("expected a page gap anomaly, got %v", g.Anomalies)
	}
}

// Extension matching is case-insensitive on disk.
func TestUppercaseExtensionAccepted(t *testing.T) {
	tr := newTree(t)
	dir := tr.galleryDir("10003-Upper")
	tr.page(dir, 1, ".JPG")
	tr.page(dir, 2, ".PNG")

	res, err := Discover(tr.downloadRoot(), LoadConfig{})
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	g := find(t, res, 10003)
	if g.PagesFound != 2 {
		t.Errorf("got %d pages, want 2", g.PagesFound)
	}
}

// ---------------------------------------------------------------------------
// Anomalies
// ---------------------------------------------------------------------------

func TestPageCountMismatch(t *testing.T) {
	tr := newTree(t)
	dir := tr.galleryDir("20000-Short")
	tr.pages(dir, 3, ".jpg")
	tr.spiderInfo(dir, 2, 20000, "tok", 5) // claims 5, disk holds 3

	res, err := Discover(tr.downloadRoot(), LoadConfig{})
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	g := find(t, res, 20000)
	if !hasAnomaly(g, models.AnomalyPageCountMismatch) {
		t.Errorf("expected page_count_mismatch, got %v", g.Anomalies)
	}
	if g.Availability != models.AvailDegraded {
		t.Errorf("availability: got %q, want %q", g.Availability, models.AvailDegraded)
	}
	// Disk wins: we still expose the 3 pages we actually have.
	if g.PagesFound != 3 {
		t.Errorf("pagesFound: got %d, want 3", g.PagesFound)
	}
}

func TestEmptyGallery(t *testing.T) {
	tr := newTree(t)
	tr.galleryDir("20001-Empty")

	res, err := Discover(tr.downloadRoot(), LoadConfig{})
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	g := find(t, res, 20001)
	if !hasAnomaly(g, models.AnomalyEmptyGallery) {
		t.Errorf("expected empty_gallery, got %v", g.Anomalies)
	}
	if g.Availability != models.AvailMissing {
		t.Errorf("availability: got %q, want %q", g.Availability, models.AvailMissing)
	}
}

func TestPageGap(t *testing.T) {
	tr := newTree(t)
	dir := tr.galleryDir("20002-Gap")
	tr.page(dir, 1, ".jpg")
	tr.page(dir, 2, ".jpg")
	tr.page(dir, 5, ".jpg") // indexes 0,1,4 - gap at 2 and 3

	res, err := Discover(tr.downloadRoot(), LoadConfig{})
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	g := find(t, res, 20002)
	if !hasAnomaly(g, models.AnomalyPageGap) {
		t.Errorf("expected page_gap, got %v", g.Anomalies)
	}
	if g.PagesFound != 3 {
		t.Errorf("pagesFound: got %d, want 3", g.PagesFound)
	}
	// Pages stay in numeric order and keep their real indexes.
	if g.Pages[2].Index != 4 {
		t.Errorf("third page index: got %d, want 4", g.Pages[2].Index)
	}
}

// Numeric ordering must not be lexicographic: 10 must come after 9.
func TestNumericPageOrdering(t *testing.T) {
	tr := newTree(t)
	dir := tr.galleryDir("20003-Order")
	for i := 1; i <= 12; i++ {
		tr.page(dir, i, ".jpg")
	}

	res, err := Discover(tr.downloadRoot(), LoadConfig{})
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	g := find(t, res, 20003)
	if len(g.Pages) != 12 {
		t.Fatalf("got %d pages, want 12", len(g.Pages))
	}
	for i, p := range g.Pages {
		if p.Index != i {
			t.Fatalf("page %d has index %d: pages are out of numeric order", i, p.Index)
		}
	}
	if last := g.Pages[11].Filename; last != "00000012.jpg" {
		t.Errorf("last page: got %q, want 00000012.jpg", last)
	}
}

func TestGIDMismatchBetweenDirAndSpiderInfo(t *testing.T) {
	tr := newTree(t)
	dir := tr.galleryDir("30000-DirName")
	tr.pages(dir, 2, ".jpg")
	tr.spiderInfo(dir, 2, 99999, "tok", 2) // .ehviewer disagrees

	res, err := Discover(tr.downloadRoot(), LoadConfig{})
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	// The .ehviewer gid becomes authoritative, and the mismatch is reported.
	g := find(t, res, 99999)
	if !hasAnomaly(g, models.AnomalyGIDMismatch) {
		t.Errorf("expected gid_mismatch, got %v", g.Anomalies)
	}
}

func TestInvalidSpiderInfoIsReportedNotFatal(t *testing.T) {
	tr := newTree(t)
	dir := tr.galleryDir("30001-BadMeta")
	tr.pages(dir, 2, ".jpg")
	tr.file(dir, spiderinfo.FileName, "this is not a spider info file\n")

	res, err := Discover(tr.downloadRoot(), LoadConfig{})
	if err != nil {
		t.Fatalf("Discover must not fail because of one bad file: %v", err)
	}
	g := find(t, res, 30001)
	if !hasAnomaly(g, models.AnomalySpiderInfoInvalid) {
		t.Errorf("expected spiderinfo_invalid, got %v", g.Anomalies)
	}
	// gid still comes from the directory name, and pages still get served.
	if g.GID != 30001 || g.PagesFound != 2 {
		t.Errorf("degraded gallery should still be usable: gid=%d pages=%d", g.GID, g.PagesFound)
	}
}

// A v1 metadata file must parse just as well as v2.
func TestVersion1SpiderInfo(t *testing.T) {
	tr := newTree(t)
	dir := tr.galleryDir("30002-V1")
	tr.pages(dir, 3, ".jpg")
	tr.spiderInfo(dir, 1, 30002, "v1token", 3)

	res, err := Discover(tr.downloadRoot(), LoadConfig{})
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	g := find(t, res, 30002)
	if g.Token != "v1token" {
		t.Errorf("token: got %q", g.Token)
	}
	if len(g.Anomalies) != 0 {
		t.Errorf("v1 metadata should be clean, got %v", g.Anomalies)
	}
}

// ---------------------------------------------------------------------------
// Syncthing noise
// ---------------------------------------------------------------------------

func TestSyncthingNoiseIgnored(t *testing.T) {
	tr := newTree(t)
	dir := tr.galleryDir("40000-Noise")
	tr.pages(dir, 2, ".jpg")
	tr.spiderInfo(dir, 2, 40000, "tok", 2)

	// Noise that must not be treated as pages or galleries.
	tr.file(dir, "~syncthing~00000003.jpg.tmp", "partial transfer")
	tr.page(dir, 3, ".jpg") // real page 3
	if err := os.WriteFile(filepath.Join(tr.downloadRoot(), "~syncthing~5000-X.tmp"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	tr.file(tr.downloadRoot(), ".stignore", "image\n")

	res, err := Discover(tr.downloadRoot(), LoadConfig{})
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	g := find(t, res, 40000)
	if g.PagesFound != 3 {
		t.Errorf("pagesFound: got %d, want 3 (the .tmp must be skipped)", g.PagesFound)
	}
	if !hasAnomaly(g, models.AnomalyPageCountMismatch) {
		t.Errorf("expected a count mismatch against the declared 2 pages, got %v", g.Anomalies)
	}
}

func TestConflictCopiesSkipped(t *testing.T) {
	tr := newTree(t)
	dir := tr.galleryDir("40001-Conf")
	tr.pages(dir, 1, ".jpg")
	tr.file(dir, "00000002.sync-conflict-20240101-120000-ABCDEFG.jpg", "conflict copy")

	res, err := Discover(tr.downloadRoot(), LoadConfig{})
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	g := find(t, res, 40001)
	if g.PagesFound != 1 {
		t.Errorf("pagesFound: got %d, want 1 (conflict copies are skipped)", g.PagesFound)
	}
}

func TestNonGalleryDirectoriesReportedNotIndexed(t *testing.T) {
	tr := newTree(t)
	good := tr.galleryDir("50000-Real")
	tr.pages(good, 1, ".jpg")
	tr.galleryDir("2024-01-01-backup") // date-like, must not look like a gid
	tr.galleryDir("thumbnails")

	res, err := Discover(tr.downloadRoot(), LoadConfig{})
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	if len(res.Galleries) != 1 {
		t.Errorf("got %d galleries, want 1", len(res.Galleries))
	}
	if len(res.Skipped) != 2 {
		t.Errorf("got %d skipped entries, want 2: %+v", len(res.Skipped), res.Skipped)
	}
	for _, s := range res.Skipped {
		if !strings.Contains(s.Reason, "<gid>-<title>") {
			t.Errorf("skip reason should explain the naming rule, got %q", s.Reason)
		}
	}
}

func TestDirNameWithDashesInTitle(t *testing.T) {
	tr := newTree(t)
	dir := tr.galleryDir("60000-A-Title-With-Dashes")
	tr.pages(dir, 1, ".jpg")

	res, err := Discover(tr.downloadRoot(), LoadConfig{})
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	g := find(t, res, 60000)
	// Only the first dash separates gid from title.
	if g.Title != "A-Title-With-Dashes" {
		t.Errorf("title: got %q, want %q", g.Title, "A-Title-With-Dashes")
	}
}

func TestEmptyDirNameTitle(t *testing.T) {
	tr := newTree(t)
	dir := tr.galleryDir("60001-")
	tr.pages(dir, 1, ".jpg")

	res, err := Discover(tr.downloadRoot(), LoadConfig{})
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	g := find(t, res, 60001)
	if g.Title != "" {
		t.Errorf("title: got %q, want empty", g.Title)
	}
	if g.GID != 60001 {
		t.Errorf("gid: got %d", g.GID)
	}
}

func TestParseDirName(t *testing.T) {
	cases := []struct {
		in     string
		gid    int64
		title  string
		wantOK bool
	}{
		{"1234567-title", 1234567, "title", true},
		{"1234567-", 1234567, "", true},
		{"1234567-a-b-c", 1234567, "a-b-c", true},
		{"12345-title", 12345, "title", true},                // 5 digits: at the floor
		{"1234-title", 0, "1234-title", false},               // 4 digits: below the floor
		{"123-title", 0, "123-title", false},                 // 3 digits: below the floor
		{"abc-title", 0, "abc-title", false},                 // no gid
		{"2024-01-01-backup", 0, "2024-01-01-backup", false}, // date-like: rejected
		{"12345678901234-x", 0, "12345678901234-x", false},   // 14 digits: above the cap
		{"title-only", 0, "title-only", false},
		{"-title", 0, "-title", false}, // empty gid
	}
	for _, c := range cases {
		gid, title, ok := ParseDirName(c.in)
		if ok != c.wantOK {
			t.Errorf("ParseDirName(%q) ok = %v, want %v", c.in, ok, c.wantOK)
			continue
		}
		if gid != c.gid || title != c.title {
			t.Errorf("ParseDirName(%q) = (%d, %q), want (%d, %q)",
				c.in, gid, title, c.gid, c.title)
		}
	}
}

func TestDiscoverMissingRootIsAnError(t *testing.T) {
	_, err := Discover(filepath.Join(t.TempDir(), "nope"), LoadConfig{})
	if err == nil {
		t.Fatal("expected an error for a missing download root")
	}
}

func TestDiscoverEmptyRoot(t *testing.T) {
	tr := newTree(t)
	if err := os.MkdirAll(tr.downloadRoot(), 0o755); err != nil {
		t.Fatal(err)
	}
	res, err := Discover(tr.downloadRoot(), LoadConfig{})
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	if len(res.Galleries) != 0 {
		t.Errorf("got %d galleries, want 0", len(res.Galleries))
	}
}
