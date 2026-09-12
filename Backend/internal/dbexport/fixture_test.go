package dbexport

import (
	"bytes"
	"database/sql"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"testing"

	"github.com/warren/ehviewer-webd/internal/models"
	"github.com/warren/ehviewer-webd/internal/spiderinfo"
)

// TestWriteFixtureTree builds a small synthetic synced EhViewer tree on disk,
// including a real exported-DB snapshot.
//
// It is skipped unless EHW_FIXTURE_DIR is set, in which case it writes the tree
// there. Its purpose is manual end-to-end verification: point the real binary
// at the generated tree and exercise the HTTP surface, which is the one thing
// httptest-based tests cannot cover (a real socket, the config loader, the scan
// subcommand, signal handling).
//
//	EHW_FIXTURE_DIR=/tmp/ehw go test ./internal/dbexport -run TestWriteFixtureTree -v
func TestWriteFixtureTree(t *testing.T) {
	dir := os.Getenv("EHW_FIXTURE_DIR")
	if dir == "" {
		t.Skip("set EHW_FIXTURE_DIR to generate the fixture tree")
	}

	download := filepath.Join(dir, "download")
	dataDir := filepath.Join(dir, "data")
	for _, d := range []string{download, dataDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", d, err)
		}
	}

	page := tinyPNG(t)

	type spec struct {
		dirName  string
		gid      int64
		token    string
		pages    int
		declared int // 0 means "same as pages"
		version  int // 0 means "no .ehviewer"
	}
	specs := []spec{
		{dirName: "1234567-Sample Gallery One", gid: 1234567, token: "tok1", pages: 5, version: 2},
		{dirName: "1234568-Second Gallery (Chinese)", gid: 1234568, token: "tok2", pages: 3, version: 2},
		// Declares more pages than exist: must surface as page_count_mismatch.
		{dirName: "1234569-Interrupted Download", gid: 1234569, token: "tok3",
			pages: 2, declared: 9, version: 2},
		// Old metadata format.
		{dirName: "1234570-Legacy Metadata", gid: 1234570, token: "tok4", pages: 4, version: 1},
		// No metadata file at all.
		{dirName: "1234571-No Metadata", gid: 1234571, pages: 2, version: 0},
		// A page gap: 1, 2 then 6.
		{dirName: "1234572-Page Gap", gid: 1234572, token: "tok6", pages: 2, version: 2},
		// Not galleries: must be reported as skipped, not indexed.
		{dirName: "thumbnails", gid: 0, pages: 1, version: 0},
		{dirName: "2024-01-01-backup", gid: 0, pages: 1, version: 0},
	}

	for _, s := range specs {
		gdir := filepath.Join(download, s.dirName)
		if err := os.MkdirAll(gdir, 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", gdir, err)
		}
		for i := 1; i <= s.pages; i++ {
			name := fileName(i)
			if err := os.WriteFile(filepath.Join(gdir, name), page, 0o644); err != nil {
				t.Fatalf("write page: %v", err)
			}
		}
		if s.gid == 1234572 {
			// Add a far-off page number to create a gap.
			if err := os.WriteFile(filepath.Join(gdir, fileName(6)), page, 0o644); err != nil {
				t.Fatal(err)
			}
		}
		if s.version != 0 {
			declared := s.declared
			if declared == 0 {
				declared = s.pages
			}
			if s.gid == 1234572 {
				declared = 3 // declares 3, disk holds indexes 0,1,5
			}
			// Use the real serializer so the fixture cannot drift from the
			// format the parser expects.
			text, err := spiderinfo.Format(models.SpiderInfo{
				Version:        s.version,
				GID:            s.gid,
				Token:          s.token,
				PreviewPages:   1,
				PreviewPerPage: 20,
				Pages:          declared,
			})
			if err != nil {
				t.Fatalf("Format: %v", err)
			}
			if err := os.WriteFile(filepath.Join(gdir, spiderinfo.FileName), []byte(text), 0o644); err != nil {
				t.Fatalf("write .ehviewer: %v", err)
			}
		}
	}

	// Syncthing noise, which must be ignored by the scanner.
	if err := os.WriteFile(filepath.Join(download, "~syncthing~9999999.tmp"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(download, ".stignore"), []byte("image\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	snapshot := filepath.Join(dataDir, "20240101120000.db")
	writeSnapshot(t, snapshot)

	t.Logf("fixture tree written to %s", dir)
	t.Logf("snapshot: %s", snapshot)
}

func writeSnapshot(t *testing.T, snapshot string) {
	t.Helper()

	db, err := sql.Open("sqlite", "file:"+filepath.ToSlash(snapshot))
	if err != nil {
		t.Fatalf("open snapshot: %v", err)
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
		// Present in a real export but unused by this service.
		`CREATE TABLE "HISTORY" ("GID" INTEGER PRIMARY KEY NOT NULL, "TITLE" TEXT)`,
	} {
		if _, err := db.Exec(ddl); err != nil {
			t.Fatalf("ddl: %v", err)
		}
	}
	if _, err := db.Exec("PRAGMA user_version = 8"); err != nil {
		t.Fatal(err)
	}

	rows := []struct {
		gid      int64
		title    string
		token    string
		category int
		rating   float64
		lang     string
		label    string
		uploader string
		timeMS   int64
	}{
		// 1234567 is deliberately absent, so that gallery must fall back to the
		// directory name and report title_source="dirname".
		// SIMPLE_LANGUAGE NULL on purpose: the export has no Gallery_Tags, so
		// the service must derive the language from the title instead.
		{1234568, "Second Gallery (Chinese)", "tok2", 1, 4.5, "", "默认", "artist-a", 1700000002000},
		{1234569, "Interrupted Download", "tok3", 2, 3.0, "", "画集", "artist-b", 1700000003000},
		{1234570, "Legacy Metadata", "tok4", 1, 4.0, "ZH", "默认", "artist-c", 1700000004000},
		{1234571, "No Metadata", "tok5", 3, 2.5, "", "", "artist-d", 1700000005000},
		{1234572, "Page Gap", "tok6", 1, 3.5, "", "默认", "artist-f", 1700000006000},
		// Orphan: in the DB, no directory on disk.
		{7654321, "Not Synced Yet", "tok9", 1, 5.0, "", "默认", "artist-e", 1700000009000},
	}
	for _, r := range rows {
		if _, err := db.Exec(
			`INSERT INTO "DOWNLOADS" (GID,TOKEN,TITLE,TITLE_JPN,THUMB,CATEGORY,POSTED,UPLOADER,
			 RATING,SIMPLE_LANGUAGE,STATE,LEGACY,TIME,LABEL,ARCHIVE_URI)
			 VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
			r.gid, r.token, r.title, "", "", r.category, "2024-01-02 03:04",
			r.uploader, r.rating, nullable(r.lang), 3, 0, r.timeMS, nullable(r.label), nil,
		); err != nil {
			t.Fatalf("insert %d: %v", r.gid, err)
		}
	}
	for i, l := range []string{"默认", "画集"} {
		if _, err := db.Exec(
			`INSERT INTO "DOWNLOAD_LABELS" (ID,LABEL,TIME) VALUES (?,?,?)`,
			i+1, l, int64(1600000000000)); err != nil {
			t.Fatal(err)
		}
	}
	for gid, name := range map[int64]string{
		1234568: "1234568-Second Gallery (Chinese)",
		1234569: "1234569-Interrupted Download",
	} {
		if _, err := db.Exec(
			`INSERT INTO "DOWNLOAD_DIRNAME" (GID,DIRNAME) VALUES (?,?)`, gid, name); err != nil {
			t.Fatal(err)
		}
	}
}

func nullable(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func fileName(i int) string {
	s := itoa(i)
	for len(s) < 8 {
		s = "0" + s
	}
	return s + ".png"
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

// tinyPNG encodes a small PNG with the standard library so the thumbnail path
// decodes a real image.
func tinyPNG(t *testing.T) []byte {
	t.Helper()
	const w, h = 32, 32
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.Set(x, y, color.RGBA{R: uint8(x * 8), G: uint8(y * 8), B: 0x80, A: 0xff})
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatalf("encode png: %v", err)
	}
	return buf.Bytes()
}
