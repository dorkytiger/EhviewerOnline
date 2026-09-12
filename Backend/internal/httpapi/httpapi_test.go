package httpapi

import (
	"bytes"
	"crypto/sha256"
	"database/sql"
	"encoding/binary"
	"encoding/json"
	"hash/crc32"
	"image"
	"image/color"
	"image/png"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/warren/ehviewer-webd/internal/auth"
	"github.com/warren/ehviewer-webd/internal/dbexport"
	"github.com/warren/ehviewer-webd/internal/index"
	"github.com/warren/ehviewer-webd/internal/models"
	"github.com/warren/ehviewer-webd/internal/scan"
	"github.com/warren/ehviewer-webd/internal/spiderinfo"
	"github.com/warren/ehviewer-webd/internal/thumbcache"

	_ "modernc.org/sqlite"
)

// ---------------------------------------------------------------------------
// Synthetic synced tree
// ---------------------------------------------------------------------------

type testEnv struct {
	t       *testing.T
	root    string
	handler http.Handler
}

type gallerySpec struct {
	dirName string // "<gid>-<title>"
	gid     int64
	token   string
	pages   int
	ext     string
	// spiderVersion of 0 means "write no .ehviewer".
	spiderVersion int
	// declaredPages overrides the page count written into .ehviewer, to
	// simulate an interrupted download.
	declaredPages int
}

func newTestEnv(t *testing.T, specs []gallerySpec, db *testDB) *testEnv {
	t.Helper()
	root := t.TempDir()
	download := filepath.Join(root, "download")
	if err := os.MkdirAll(download, 0o755); err != nil {
		t.Fatal(err)
	}

	for _, spec := range specs {
		dir := filepath.Join(download, spec.dirName)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		for i := 1; i <= spec.pages; i++ {
			name := pad8(i) + spec.ext
			if err := os.WriteFile(filepath.Join(dir, name), testPNG(t, 24, 32), 0o644); err != nil {
				t.Fatal(err)
			}
		}
		if spec.spiderVersion != 0 {
			declared := spec.declaredPages
			if declared == 0 {
				declared = spec.pages
			}
			text, err := spiderinfo.Format(models.SpiderInfo{
				Version:        spec.spiderVersion,
				GID:            spec.gid,
				Token:          spec.token,
				PreviewPages:   1,
				PreviewPerPage: 20,
				Pages:          declared,
			})
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(dir, spiderinfo.FileName), []byte(text), 0o644); err != nil {
				t.Fatal(err)
			}
		}
	}

	var merged *dbexport.Merged
	var dbErrs []error
	if db != nil {
		dbPath := filepath.Join(root, "data", "20240101120000.db")
		db.write(t, dbPath)
		cands, err := dbexport.ListCandidates(filepath.Dir(dbPath))
		if err != nil {
			t.Fatal(err)
		}
		merged, dbErrs = dbexport.LoadAll(cands, dbexport.PolicyLatest)
		if len(dbErrs) != 0 {
			t.Fatalf("snapshot errors: %v", dbErrs)
		}
	}

	scanned, err := scan.Discover(download, scan.LoadConfig{})
	if err != nil {
		t.Fatal(err)
	}

	idx := index.Build(index.BuildInput{
		Scanned:  scanned,
		Merged:   merged,
		DBErrors: dbErrs,
	})

	thumbs, err := thumbcache.New(thumbcache.Options{
		Dir:     filepath.Join(t.TempDir(), "thumbs"),
		MaxDim:  16,
		Workers: 1,
	})
	if err != nil {
		t.Fatal(err)
	}

	srv, err := New(Options{
		Store:                index.NewStore(idx),
		Auth:                 nil, // replaced by the manager below
		Thumbs:               thumbs,
		Logger:               slog.New(slog.NewTextHandler(io.Discard, nil)),
		Roots:                []string{root},
		RootsConfigured:      true,
		AllowUnauthenticated: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	return &testEnv{t: t, root: root, handler: srv.Handler()}
}

func (e *testEnv) get(path string) *httptest.ResponseRecorder {
	e.t.Helper()
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
	return rec
}

func decodeJSON[T any](t *testing.T, rec *httptest.ResponseRecorder) T {
	t.Helper()
	var v T
	if err := json.Unmarshal(rec.Body.Bytes(), &v); err != nil {
		t.Fatalf("decode JSON: %v\nbody=%s", err, rec.Body.String())
	}
	return v
}

// testPNG produces a real, decodable PNG so the thumbnail path exercises an
// actual decode rather than a stub.
func testPNG(t *testing.T, w, h int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.Set(x, y, color.RGBA{R: uint8(x * 8), G: uint8(y * 8), B: 128, A: 255})
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func pad8(n int) string {
	s := ""
	for i := len(itoa(n)); i < 8; i++ {
		s += "0"
	}
	return s + itoa(n)
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}

// ---------------------------------------------------------------------------
// Synthetic exported DB
// ---------------------------------------------------------------------------

type testDB struct {
	rows     []testDBRow
	labels   []string
	dirNames map[int64]string
}

type testDBRow struct {
	gid      int64
	title    string
	token    string
	category int
	rating   float64
	lang     string
	label    string
	updater  string
	state    int
	timeMS   int64
}

func (d *testDB) write(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", "file:"+filepath.ToSlash(path))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	for _, ddl := range []string{
		`CREATE TABLE "DOWNLOADS" (
			"GID" INTEGER PRIMARY KEY NOT NULL, "TOKEN" TEXT, "TITLE" TEXT,
			"TITLE_JPN" TEXT, "THUMB" TEXT, "CATEGORY" INTEGER NOT NULL,
			"POSTED" TEXT, "UPLOADER" TEXT, "RATING" REAL NOT NULL,
			"SIMPLE_LANGUAGE" TEXT, "STATE" INTEGER NOT NULL, "LEGACY" INTEGER NOT NULL,
			"TIME" INTEGER NOT NULL, "LABEL" TEXT, "ARCHIVE_URI" TEXT)`,
		`CREATE TABLE "DOWNLOAD_LABELS" ("ID" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
			"LABEL" TEXT NOT NULL, "TIME" INTEGER NOT NULL)`,
		`CREATE TABLE "DOWNLOAD_DIRNAME" ("GID" INTEGER PRIMARY KEY NOT NULL, "DIRNAME" TEXT)`,
	} {
		if _, err := db.Exec(ddl); err != nil {
			t.Fatalf("ddl: %v", err)
		}
	}
	if _, err := db.Exec("PRAGMA user_version = 8"); err != nil {
		t.Fatal(err)
	}
	for _, r := range d.rows {
		if _, err := db.Exec(
			`INSERT INTO "DOWNLOADS" (GID,TOKEN,TITLE,TITLE_JPN,THUMB,CATEGORY,POSTED,UPLOADER,
			 RATING,SIMPLE_LANGUAGE,STATE,LEGACY,TIME,LABEL,ARCHIVE_URI)
			 VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
			r.gid, r.token, r.title, "", "", r.category, "2024-01-02 03:04",
			r.updater, r.rating, r.lang, r.state, 0, r.timeMS, r.label, nil,
		); err != nil {
			t.Fatalf("insert row: %v", err)
		}
	}
	for i, l := range d.labels {
		if _, err := db.Exec(`INSERT INTO "DOWNLOAD_LABELS" (ID,LABEL,TIME) VALUES (?,?,?)`,
			i+1, l, int64(1600000000000)); err != nil {
			t.Fatalf("insert label: %v", err)
		}
	}
	for gid, name := range d.dirNames {
		if _, err := db.Exec(`INSERT INTO "DOWNLOAD_DIRNAME" (GID,DIRNAME) VALUES (?,?)`,
			gid, name); err != nil {
			t.Fatalf("insert dirname: %v", err)
		}
	}
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

func TestHealthzIsUnauthenticated(t *testing.T) {
	env := newTestEnv(t, nil, nil)
	rec := env.get("/healthz")
	if rec.Code != http.StatusOK {
		t.Fatalf("status: got %d, want 200", rec.Code)
	}
	var body map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body["status"] != "ok" {
		t.Errorf("body: %v", body)
	}
	// The probe must not leak library size.
	if strings.Contains(rec.Body.String(), "galleries") {
		t.Error("healthz should not disclose index statistics")
	}
}

func TestGalleryListMergesDBOverDirectoryName(t *testing.T) {
	db := &testDB{
		rows: []testDBRow{
			// SIMPLE_LANGUAGE deliberately NULL: the export has no tags, so
			// this is the common case and language must come from the title.
			{gid: 1234567, title: "Real Title (English)", token: "tok-1", category: 1,
				rating: 4.5, lang: "", label: "默认", updater: "artist", state: 3,
				timeMS: 1700000000000},
		},
		labels:   []string{"默认"},
		dirNames: map[int64]string{1234567: "1234567-DirNameFromDisk"},
	}
	env := newTestEnv(t, []gallerySpec{
		{dirName: "1234567-DirNameFromDisk", gid: 1234567, token: "tok-1",
			pages: 3, ext: ".png", spiderVersion: 2},
	}, db)

	rec := env.get("/api/v1/galleries")
	if rec.Code != http.StatusOK {
		t.Fatalf("status: got %d, body=%s", rec.Code, rec.Body.String())
	}
	list := decodeJSON[galleryListDTO](t, rec)

	if list.Total != 1 || len(list.Items) != 1 {
		t.Fatalf("expected 1 gallery, got total=%d items=%d", list.Total, len(list.Items))
	}
	item := list.Items[0]

	// DB title wins over the directory name.
	if item.Title != "Real Title (English)" {
		t.Errorf("title: got %q, want the DB title", item.Title)
	}
	if item.TitleSource != models.TitleSourceDB {
		t.Errorf("title_source: got %q, want %q", item.TitleSource, models.TitleSourceDB)
	}
	if item.MetaSource != models.MetaSourceDB {
		t.Errorf("meta_source: got %q", item.MetaSource)
	}
	// Language derived from the title because SIMPLE_LANGUAGE was NULL.
	if item.SimpleLanguage != "EN" {
		t.Errorf("simple_language: got %q, want EN (derived from the title)", item.SimpleLanguage)
	}
	if item.Rating != 4.5 || item.Category != 1 || item.Label != "默认" {
		t.Errorf("db fields not applied: %+v", item)
	}
	if item.PagesFound != 3 {
		t.Errorf("pages_found: got %d, want 3 (filesystem wins)", item.PagesFound)
	}
	if item.Availability != string(models.AvailOK) {
		t.Errorf("availability: got %q (anomalies %v)", item.Availability, item.Anomalies)
	}
	if item.CoverURL == "" {
		t.Error("cover_url should be set")
	}
	if list.SnapshotAtMS == 0 {
		t.Error("snapshot_at_ms should reflect the DB snapshot")
	}
	// The list projection must not carry the page array.
	if strings.Contains(rec.Body.String(), "pages_detail") {
		t.Error("the list endpoint must not include per-page detail")
	}
}

// A DB row whose directory is absent must still be returned, marked missing.
// Otherwise a not-yet-synced gallery looks like data loss.
func TestOrphanDBRowIsReturnedAsMissing(t *testing.T) {
	db := &testDB{
		rows: []testDBRow{
			{gid: 7654321, title: "Not Synced Yet", token: "tok-2", state: 3, category: 2,
				timeMS: 1700000001000},
		},
	}
	env := newTestEnv(t, []gallerySpec{
		{dirName: "1234567-Present", gid: 1234567, pages: 1, ext: ".png", spiderVersion: 2},
	}, db)

	rec := env.get("/api/v1/galleries")
	list := decodeJSON[galleryListDTO](t, rec)
	if list.Total != 2 {
		t.Fatalf("expected 2 galleries (one on disk, one orphan), got %d", list.Total)
	}

	var orphan *GalleryDTO
	for i := range list.Items {
		if list.Items[i].GID == 7654321 {
			orphan = &list.Items[i]
		}
	}
	if orphan == nil {
		t.Fatal("orphan DB row was dropped")
	}
	if orphan.Availability != string(models.AvailMissing) {
		t.Errorf("availability: got %q, want %q", orphan.Availability, models.AvailMissing)
	}
	if orphan.OnDisk {
		t.Error("on_disk should be false for an orphan")
	}
	if orphan.Title != "Not Synced Yet" {
		t.Errorf("title: got %q", orphan.Title)
	}
	if orphan.MetaSource != models.MetaSourceOrphan {
		t.Errorf("meta_source: got %q", orphan.MetaSource)
	}
}

// With no snapshot at all the service must still work, using directory names.
func TestLocalOnlyModeWithoutSnapshot(t *testing.T) {
	env := newTestEnv(t, []gallerySpec{
		{dirName: "1234567-Some Title", gid: 1234567, pages: 2, ext: ".png", spiderVersion: 2},
	}, nil)

	rec := env.get("/api/v1/galleries")
	list := decodeJSON[galleryListDTO](t, rec)
	if list.Total != 1 {
		t.Fatalf("got %d galleries", list.Total)
	}
	item := list.Items[0]
	if item.Title != "Some Title" {
		t.Errorf("title: got %q, want the directory-name fallback", item.Title)
	}
	if item.TitleSource != models.TitleSourceDirname {
		t.Errorf("title_source: got %q", item.TitleSource)
	}
	if item.MetaSource != models.MetaSourceLocalOnly {
		t.Errorf("meta_source: got %q", item.MetaSource)
	}

	meta := decodeJSON[map[string]any](t, env.get("/api/v1/meta"))
	warnings, _ := meta["warnings"].([]any)
	if len(warnings) == 0 {
		t.Error("expected a warning explaining that no snapshot was found")
	}
}

func TestGalleryDetailIncludesPagesAndSpiderInfo(t *testing.T) {
	env := newTestEnv(t, []gallerySpec{
		{dirName: "1234567-Detail", gid: 1234567, token: "tok", pages: 4, ext: ".png",
			spiderVersion: 2},
	}, nil)

	rec := env.get("/api/v1/galleries/1234567")
	if rec.Code != http.StatusOK {
		t.Fatalf("status: got %d, body=%s", rec.Code, rec.Body.String())
	}
	detail := decodeJSON[GalleryDetailDTO](t, rec)

	if len(detail.PagesDetail) != 4 {
		t.Fatalf("pages_detail: got %d, want 4", len(detail.PagesDetail))
	}
	// Zero-based index, one-based filename, served URL.
	first := detail.PagesDetail[0]
	if first.Index != 0 || first.Filename != "00000001.png" || first.URL != "/img/1234567/0" {
		t.Errorf("first page: %+v", first)
	}
	if last := detail.PagesDetail[3]; last.Index != 3 || last.URL != "/img/1234567/3" {
		t.Errorf("last page: %+v", last)
	}
	if detail.SpiderInfo == nil || !detail.SpiderInfo.Present {
		t.Fatalf("spider_info should be present: %+v", detail.SpiderInfo)
	}
	if detail.SpiderInfo.Version != 2 || detail.SpiderInfo.Pages != 4 ||
		detail.SpiderInfo.PreviewPerPage != 20 {
		t.Errorf("spider_info should report the real values: %+v", detail.SpiderInfo)
	}
	if detail.PrevGID != 0 {
		t.Errorf("prev_gid should be absent for the only gallery, got %d", detail.PrevGID)
	}
}

// When .ehviewer is absent the detail must say so explicitly rather than
// inventing preview counts.
func TestGalleryDetailReportsAbsentSpiderInfo(t *testing.T) {
	env := newTestEnv(t, []gallerySpec{
		{dirName: "1234567-NoMeta", gid: 1234567, pages: 2, ext: ".png", spiderVersion: 0},
	}, nil)

	rec := env.get("/api/v1/galleries/1234567")
	detail := decodeJSON[GalleryDetailDTO](t, rec)
	if detail.SpiderInfo == nil {
		t.Fatal("spider_info should always be present in the response")
	}
	if detail.SpiderInfo.Present {
		t.Error("spider_info.present must be false when there is no metadata file")
	}
	if detail.Token != "" {
		t.Errorf("token should be empty without .ehviewer, got %q", detail.Token)
	}
	if len(detail.Anomalies) == 0 {
		t.Error("a missing page count should surface as an anomaly")
	}
	_ = detail
}

func TestImageServing(t *testing.T) {
	env := newTestEnv(t, []gallerySpec{
		{dirName: "1234567-Img", gid: 1234567, pages: 3, ext: ".png", spiderVersion: 2},
	}, nil)

	rec := env.get("/img/1234567/0")
	if rec.Code != http.StatusOK {
		t.Fatalf("status: got %d", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "image/png" {
		t.Errorf("content-type: got %q, want image/png", ct)
	}
	if rec.Header().Get("X-Content-Type-Options") != "nosniff" {
		t.Error("nosniff header missing")
	}
	if !strings.Contains(rec.Header().Get("Cache-Control"), "immutable") {
		t.Errorf("cache-control: got %q", rec.Header().Get("Cache-Control"))
	}
	if rec.Body.Len() == 0 {
		t.Error("empty image body")
	}
	// The bytes must be the real file.
	want, err := os.ReadFile(filepath.Join(env.root, "download", "1234567-Img", "00000001.png"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(rec.Body.Bytes(), want) {
		t.Errorf("body does not match the source file (%d vs %d bytes)",
			rec.Body.Len(), len(want))
	}
}

func TestImageServingSupportsConditionalGET(t *testing.T) {
	env := newTestEnv(t, []gallerySpec{
		{dirName: "1234567-Img", gid: 1234567, pages: 1, ext: ".png", spiderVersion: 2},
	}, nil)

	first := env.get("/img/1234567/0")
	etag := first.Header().Get("ETag")
	if etag == "" {
		t.Fatal("expected an ETag so clients can revalidate")
	}

	req := httptest.NewRequest(http.MethodGet, "/img/1234567/0", nil)
	req.Header.Set("If-None-Match", etag)
	rec := httptest.NewRecorder()
	env.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusNotModified {
		t.Errorf("status: got %d, want 304", rec.Code)
	}
	if rec.Body.Len() != 0 {
		t.Error("a 304 must not carry a body")
	}
}

func TestImageOutOfRangeIs404(t *testing.T) {
	env := newTestEnv(t, []gallerySpec{
		{dirName: "1234567-Img", gid: 1234567, pages: 2, ext: ".png", spiderVersion: 2},
	}, nil)

	for _, path := range []string{
		"/img/1234567/2",  // one past the end
		"/img/1234567/99", // far past the end
		"/img/9999999/0",  // unknown gallery
	} {
		rec := env.get(path)
		if rec.Code != http.StatusNotFound {
			t.Errorf("%s: got %d, want 404", path, rec.Code)
		}
	}

	// A negative index and a non-numeric gid are client errors, not 404s.
	for _, path := range []string{"/img/1234567/-1", "/img/abc/0"} {
		rec := env.get(path)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("%s: got %d, want 400", path, rec.Code)
		}
	}
}

// Traversal attempts must never reach a file.
//
// Three outcomes are all safe, and the test distinguishes them because they
// come from different mechanisms:
//
//   - 307: http.ServeMux normalizes literal "." and ".." segments *before*
//     route matching and redirects. The redirect target must itself be free of
//     ".." segments and still inside our route space, which is what this
//     assertion checks, because a redirect to an attacker-influenced path
//     would be a real problem.
//   - 400: a percent-encoded traversal reaches the handler (ServeMux
//     deliberately does not decode, so it cannot be normalized away) and fails
//     to parse as a page index.
//   - 404: it parses but resolves to nothing.
//
// The important property is that the page filename always comes from the
// index, so there is no path to traverse in the first place.
func TestImageTraversalAttemptsAreRejected(t *testing.T) {
	env := newTestEnv(t, []gallerySpec{
		{dirName: "1234567-Img", gid: 1234567, pages: 1, ext: ".png", spiderVersion: 2},
	}, nil)

	for _, path := range []string{
		"/img/1234567/../../../../windows/win.ini",
		"/img/1234567/%2e%2e%2f%2e%2e%2fetc%2fpasswd",
		"/img/1234567/..",
		"/img/1234567/0/../../secret",
	} {
		rec := env.get(path)
		switch {
		case rec.Code >= 200 && rec.Code < 300:
			t.Errorf("%s: served a 2xx, expected rejection", path)
		case rec.Code == http.StatusTemporaryRedirect || rec.Code == http.StatusMovedPermanently:
			loc := rec.Header().Get("Location")
			if loc == "" {
				t.Errorf("%s: redirect without a Location header", path)
				continue
			}
			if strings.Contains(loc, "..") {
				t.Errorf("%s: redirect target still contains a traversal: %q", path, loc)
			}
			if !strings.HasPrefix(loc, "/") {
				t.Errorf("%s: redirect left the origin: %q", path, loc)
			}
		case rec.Code != http.StatusBadRequest && rec.Code != http.StatusNotFound:
			t.Errorf("%s: got %d, want 400, 404 or a safe redirect", path, rec.Code)
		}
	}
}

func TestThumbnailIsRenderedAndSmallerThanSource(t *testing.T) {
	env := newTestEnv(t, []gallerySpec{
		{dirName: "1234567-Thumb", gid: 1234567, pages: 1, ext: ".png", spiderVersion: 2},
	}, nil)

	rec := env.get("/thumb/1234567")
	if rec.Code != http.StatusOK {
		t.Fatalf("status: got %d, body=%s", rec.Code, rec.Body.String())
	}
	if ct := rec.Header().Get("Content-Type"); ct != "image/jpeg" {
		t.Errorf("content-type: got %q, want image/jpeg", ct)
	}

	// The rendered thumbnail must be a valid image no larger than the source.
	cfg, format, err := image.DecodeConfig(bytes.NewReader(rec.Body.Bytes()))
	if err != nil {
		t.Fatalf("thumbnail is not a decodable image: %v", err)
	}
	if format != "jpeg" {
		t.Errorf("format: got %q, want jpeg", format)
	}
	if cfg.Width > 16 || cfg.Height > 16 {
		t.Errorf("thumbnail %dx%d exceeds the configured 16px long edge", cfg.Width, cfg.Height)
	}

	// A second request must hit the cache and return identical bytes.
	again := env.get("/thumb/1234567")
	if !bytes.Equal(rec.Body.Bytes(), again.Body.Bytes()) {
		t.Error("a cached thumbnail should be byte-identical")
	}
}

func TestThumbnailForGalleryWithoutPages(t *testing.T) {
	env := newTestEnv(t, []gallerySpec{
		{dirName: "1234567-Empty", gid: 1234567, pages: 0, spiderVersion: 2, declaredPages: 5},
	}, nil)

	rec := env.get("/thumb/1234567")
	if rec.Code != http.StatusNotFound {
		t.Errorf("status: got %d, want 404 for a gallery with no pages", rec.Code)
	}
	var body apiError
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("error body is not JSON: %s", rec.Body.String())
	}
	if body.Error.Code != "no_cover" {
		t.Errorf("error code: got %q, want no_cover", body.Error.Code)
	}
}

func TestFilteringAndSorting(t *testing.T) {
	db := &testDB{
		rows: []testDBRow{
			{gid: 1000001, title: "Alpha (Chinese)", category: 1, lang: "ZH",
				label: "默认", state: 3, timeMS: 3000},
			{gid: 1000002, title: "Beta (English)", category: 2, lang: "EN",
				label: "画集", state: 3, timeMS: 2000},
			{gid: 1000003, title: "Gamma", category: 1, lang: "ZH",
				label: "默认", state: 3, timeMS: 1000},
		},
		labels: []string{"默认", "画集"},
	}
	env := newTestEnv(t, []gallerySpec{
		{dirName: "1000001-A", gid: 1000001, pages: 1, ext: ".png", spiderVersion: 2},
		{dirName: "1000002-B", gid: 1000002, pages: 6, ext: ".png", spiderVersion: 2},
		{dirName: "1000003-C", gid: 1000003, pages: 3, ext: ".png", spiderVersion: 2},
	}, db)

	t.Run("by language", func(t *testing.T) {
		list := decodeJSON[galleryListDTO](t, env.get("/api/v1/galleries?language=ZH"))
		if list.Total != 2 {
			t.Errorf("got %d, want 2", list.Total)
		}
	})

	t.Run("by label", func(t *testing.T) {
		list := decodeJSON[galleryListDTO](t, env.get("/api/v1/galleries?label=%E7%94%BB%E9%9B%86"))
		if list.Total != 1 || list.Items[0].GID != 1000002 {
			t.Errorf("got total=%d, want just gid 1000002", list.Total)
		}
	})

	t.Run("by category", func(t *testing.T) {
		list := decodeJSON[galleryListDTO](t, env.get("/api/v1/galleries?category=1"))
		if list.Total != 2 {
			t.Errorf("got %d, want 2", list.Total)
		}
	})

	t.Run("by text", func(t *testing.T) {
		list := decodeJSON[galleryListDTO](t, env.get("/api/v1/galleries?q=english"))
		if list.Total != 1 || list.Items[0].GID != 1000002 {
			t.Errorf("text search should be case-insensitive and match the title")
		}
	})

	t.Run("by gid as text", func(t *testing.T) {
		list := decodeJSON[galleryListDTO](t, env.get("/api/v1/galleries?q=1000003"))
		if list.Total != 1 || list.Items[0].GID != 1000003 {
			t.Errorf("gid should be searchable")
		}
	})

	t.Run("sort by time desc", func(t *testing.T) {
		list := decodeJSON[galleryListDTO](t, env.get("/api/v1/galleries?sort=time_desc"))
		if list.Items[0].GID != 1000001 || list.Items[2].GID != 1000003 {
			t.Errorf("wrong order: %v", []int64{list.Items[0].GID, list.Items[1].GID, list.Items[2].GID})
		}
	})

	t.Run("sort by pages desc", func(t *testing.T) {
		list := decodeJSON[galleryListDTO](t, env.get("/api/v1/galleries?sort=pages_desc"))
		if list.Items[0].GID != 1000002 {
			t.Errorf("most pages should sort first, got %d", list.Items[0].GID)
		}
	})

	t.Run("sort by title", func(t *testing.T) {
		list := decodeJSON[galleryListDTO](t, env.get("/api/v1/galleries?sort=title"))
		if list.Items[0].Title != "Alpha (Chinese)" {
			t.Errorf("got %q first", list.Items[0].Title)
		}
	})

	t.Run("rejects an unknown sort", func(t *testing.T) {
		rec := env.get("/api/v1/galleries?sort=bogus")
		if rec.Code != http.StatusBadRequest {
			t.Errorf("status: got %d, want 400", rec.Code)
		}
	})

	t.Run("rejects a non-integer category", func(t *testing.T) {
		rec := env.get("/api/v1/galleries?category=abc")
		if rec.Code != http.StatusBadRequest {
			t.Errorf("status: got %d, want 400", rec.Code)
		}
	})
}

func TestCursorPaging(t *testing.T) {
	var specs []gallerySpec
	db := &testDB{}
	for i := 0; i < 5; i++ {
		gid := int64(2000000 + i)
		specs = append(specs, gallerySpec{
			dirName: itoa(int(gid)) + "-G", gid: gid, pages: i + 1, ext: ".png", spiderVersion: 2,
		})
		db.rows = append(db.rows, testDBRow{
			gid: gid, title: "G" + itoa(i), state: 3, timeMS: int64(1000 + i),
		})
	}
	env := newTestEnv(t, specs, db)

	seen := map[int64]bool{}
	cursor := ""
	pages := 0
	for {
		path := "/api/v1/galleries?limit=2"
		if cursor != "" {
			path += "&cursor=" + cursor
		}
		list := decodeJSON[galleryListDTO](t, env.get(path))
		for _, it := range list.Items {
			if seen[it.GID] {
				t.Fatalf("gid %d returned twice", it.GID)
			}
			seen[it.GID] = true
		}
		pages++
		if list.NextCursor == "" {
			break
		}
		cursor = list.NextCursor
		if pages > 10 {
			t.Fatal("paging did not terminate")
		}
	}
	if len(seen) != 5 {
		t.Errorf("walked %d galleries, want 5", len(seen))
	}
	if pages != 3 {
		t.Errorf("got %d pages of 2, want 3", pages)
	}
}

// A cursor is bound to its filter set so it cannot be replayed against a
// different query, which would silently skip rows.
func TestCursorIsBoundToTheQuery(t *testing.T) {
	env := newTestEnv(t, []gallerySpec{
		{dirName: "1234567-A", gid: 1234567, pages: 1, ext: ".png", spiderVersion: 2},
		{dirName: "1234568-B", gid: 1234568, pages: 1, ext: ".png", spiderVersion: 2},
	}, nil)

	list := decodeJSON[galleryListDTO](t, env.get("/api/v1/galleries?limit=1"))
	if list.NextCursor == "" {
		t.Fatal("expected a cursor")
	}
	rec := env.get("/api/v1/galleries?limit=1&label=something-else&cursor=" + list.NextCursor)
	if rec.Code != http.StatusBadRequest {
		t.Errorf("status: got %d, want 400 when a cursor is reused for another query", rec.Code)
	}

	rec = env.get("/api/v1/galleries?limit=1&cursor=not-base64!!")
	if rec.Code != http.StatusBadRequest {
		t.Errorf("status: got %d, want 400 for a malformed cursor", rec.Code)
	}
}

func TestFacets(t *testing.T) {
	db := &testDB{
		rows: []testDBRow{
			{gid: 1000001, title: "A", category: 1, lang: "ZH", label: "默认", state: 3},
			{gid: 1000002, title: "B", category: 2, lang: "EN", label: "默认", state: 3},
		},
		labels: []string{"默认", "画集"},
	}
	env := newTestEnv(t, []gallerySpec{
		{dirName: "1000001-A", gid: 1000001, pages: 1, ext: ".png", spiderVersion: 2},
		{dirName: "1000002-B", gid: 1000002, pages: 1, ext: ".png", spiderVersion: 2},
	}, db)

	f := decodeJSON[models.Facets](t, env.get("/api/v1/facets"))
	if len(f.Labels) != 1 || f.Labels[0].Value != "默认" || f.Labels[0].Count != 2 {
		t.Errorf("labels facet: %+v", f.Labels)
	}
	if len(f.Languages) != 2 {
		t.Errorf("languages facet: %+v", f.Languages)
	}
	// Categories come back as strings because the CATEGORY enum semantics live
	// in an unverifiable dependency; the client renders the raw number.
	if len(f.Categories) != 2 {
		t.Errorf("categories facet: %+v", f.Categories)
	}
	if len(f.Availability) == 0 {
		t.Error("availability facet should not be empty")
	}
}

func TestMetaReportsFeatureFlagsHonestly(t *testing.T) {
	env := newTestEnv(t, []gallerySpec{
		{dirName: "1234567-A", gid: 1234567, pages: 1, ext: ".png", spiderVersion: 2},
	}, nil)

	rec := env.get("/api/v1/meta")
	meta := decodeJSON[map[string]any](t, rec)
	features, ok := meta["features"].(map[string]any)
	if !ok {
		t.Fatalf("features missing: %v", meta)
	}
	// Tags are impossible from an export snapshot; advertising them would make
	// the client show a filter that can never match.
	if features["tags"] != false {
		t.Errorf("features.tags: got %v, want false", features["tags"])
	}
	if features["thumbnails"] != true {
		t.Errorf("features.thumbnails: got %v, want true", features["thumbnails"])
	}
	idx, ok := meta["index"].(map[string]any)
	if !ok {
		t.Fatal("index stats missing")
	}
	if idx["galleries"].(float64) != 1 {
		t.Errorf("index.galleries: got %v", idx["galleries"])
	}
}

func TestReindexRequiresLocalCaller(t *testing.T) {
	env := newTestEnv(t, nil, nil)

	// The test recorder's default RemoteAddr is not loopback, so the handler
	// must refuse before touching reindex.
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/v1/admin/reindex", nil)
	req.RemoteAddr = "203.0.113.7:1234"
	env.handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Errorf("status: got %d, want 403 for a remote reindex", rec.Code)
	}
}

// --- authentication --------------------------------------------------------

func TestAuthFlow(t *testing.T) {
	root := t.TempDir()
	download := filepath.Join(root, "download")
	if err := os.MkdirAll(download, 0o755); err != nil {
		t.Fatal(err)
	}
	scanned, err := scan.Discover(download, scan.LoadConfig{})
	if err != nil {
		t.Fatal(err)
	}
	idx := index.Build(index.BuildInput{Scanned: scanned})

	mgr, err := auth.New(auth.Options{
		Mode:       auth.ModeToken,
		Token:      "correct-horse-battery-staple",
		KeyPath:    filepath.Join(t.TempDir(), "session.key"),
		CookieName: "ehw_session",
	})
	if err != nil {
		t.Fatal(err)
	}
	srv, err := New(Options{
		Store:  index.NewStore(idx),
		Auth:   mgr,
		Logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
	})
	if err != nil {
		t.Fatal(err)
	}
	h := srv.Handler()

	// Every content route refuses an anonymous caller, images included.
	for _, path := range []string{
		"/api/v1/galleries",
		"/api/v1/meta",
		"/api/v1/facets",
		"/api/v1/galleries/1234567",
		"/img/1234567/0",
		"/thumb/1234567",
	} {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if rec.Code != http.StatusUnauthorized {
			t.Errorf("%s: got %d, want 401 without a session", path, rec.Code)
		}
		if rec.Body.Len() != 0 {
			t.Errorf("%s: a 401 must have no body, got %q", path, rec.Body.String())
		}
	}

	// The health probe stays open.
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if rec.Code != http.StatusOK {
		t.Errorf("healthz: got %d, want 200", rec.Code)
	}

	// A wrong token is rejected without revealing anything.
	rec = httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/login",
		strings.NewReader(`{"token":"wrong"}`))
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("wrong token: got %d, want 401", rec.Code)
	}
	if strings.Contains(rec.Body.String(), "correct-horse") {
		t.Error("the error response must not echo the expected token")
	}

	// The right token issues a session cookie, and that cookie unlocks reads.
	rec = httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodPost, "/api/v1/auth/login",
		strings.NewReader(`{"token":"correct-horse-battery-staple"}`))
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("login: got %d, body=%s", rec.Code, rec.Body.String())
	}
	cookies := rec.Result().Cookies()
	if len(cookies) == 0 {
		t.Fatal("login did not set a cookie")
	}
	session := cookies[0]
	if !session.HttpOnly {
		t.Error("session cookie must be HttpOnly")
	}
	if session.SameSite != http.SameSiteLaxMode {
		t.Errorf("SameSite: got %v, want Lax (Strict would drop the cookie on external links)", session.SameSite)
	}
	if session.Domain != "" {
		t.Errorf("the cookie should be host-only, got Domain=%q", session.Domain)
	}

	rec = httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodGet, "/api/v1/galleries", nil)
	req.AddCookie(session)
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Errorf("authenticated list: got %d", rec.Code)
	}

	// A tampered cookie must not authenticate.
	tampered := *session
	tampered.Value = session.Value[:len(session.Value)-2] + "xy"
	rec = httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodGet, "/api/v1/galleries", nil)
	req.AddCookie(&tampered)
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("tampered session: got %d, want 401", rec.Code)
	}
}

func TestLoginRejectsMalformedBody(t *testing.T) {
	mgr, err := auth.New(auth.Options{
		Mode:    auth.ModeToken,
		Token:   "t",
		KeyPath: filepath.Join(t.TempDir(), "k"),
	})
	if err != nil {
		t.Fatal(err)
	}
	srv, err := New(Options{
		Store:  index.NewStore(index.Build(index.BuildInput{Scanned: &scan.Result{}})),
		Auth:   mgr,
		Logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
	})
	if err != nil {
		t.Fatal(err)
	}
	h := srv.Handler()

	for _, body := range []string{``, `{`, `[]`, `{"nope":1}`} {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/api/v1/auth/login",
			strings.NewReader(body)))
		if rec.Code != http.StatusBadRequest {
			t.Errorf("body %q: got %d, want 400", body, rec.Code)
		}
	}
}

// A very long body must be rejected rather than buffered.
func TestLoginRejectsOversizedBody(t *testing.T) {
	mgr, err := auth.New(auth.Options{
		Mode: auth.ModeToken, Token: "t", KeyPath: filepath.Join(t.TempDir(), "k"),
	})
	if err != nil {
		t.Fatal(err)
	}
	srv, err := New(Options{
		Store:  index.NewStore(index.Build(index.BuildInput{Scanned: &scan.Result{}})),
		Auth:   mgr,
		Logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
	})
	if err != nil {
		t.Fatal(err)
	}
	big := `{"token":"` + strings.Repeat("A", 100_000) + `"}`
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/api/v1/auth/login",
		strings.NewReader(big)))
	if rec.Code != http.StatusBadRequest && rec.Code != http.StatusRequestEntityTooLarge {
		t.Errorf("status: got %d, want 400 or 413", rec.Code)
	}
}

// The log middleware must not break the SSE-style flushing used by future
// streaming endpoints.
func TestStatusRecorderExposesFlusher(t *testing.T) {
	inner := httptest.NewRecorder()
	rec := &statusRecorder{ResponseWriter: inner}
	if _, ok := any(rec).(http.Flusher); !ok {
		t.Fatal("statusRecorder must implement http.Flusher")
	}
}

var _ = crc32.ChecksumIEEE
var _ = binary.BigEndian
var _ = sha256.Sum256
