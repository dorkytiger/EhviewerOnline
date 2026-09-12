package dbexport

import (
	"database/sql"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	_ "modernc.org/sqlite"
)

// schemaDDL mirrors what the greenDAO daogenerator emits for schema version 8.
// Column names and order are taken from DownloadsDao.java:206-220,
// DownloadLabel.java and DownloadDirname.java.
const downloadsDDL = `
CREATE TABLE "DOWNLOADS" (
	"GID" INTEGER PRIMARY KEY NOT NULL,
	"TOKEN" TEXT,
	"TITLE" TEXT,
	"TITLE_JPN" TEXT,
	"THUMB" TEXT,
	"CATEGORY" INTEGER NOT NULL,
	"POSTED" TEXT,
	"UPLOADER" TEXT,
	"RATING" REAL NOT NULL,
	"SIMPLE_LANGUAGE" TEXT,
	"STATE" INTEGER NOT NULL,
	"LEGACY" INTEGER NOT NULL,
	"TIME" INTEGER NOT NULL,
	"LABEL" TEXT,
	"ARCHIVE_URI" TEXT
);`

const labelsDDL = `
CREATE TABLE "DOWNLOAD_LABELS" (
	"ID" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
	"LABEL" TEXT NOT NULL,
	"TIME" INTEGER NOT NULL
);`

const dirnameDDL = `
CREATE TABLE "DOWNLOAD_DIRNAME" (
	"GID" INTEGER PRIMARY KEY NOT NULL,
	"DIRNAME" TEXT
);`

type fixtureRow struct {
	gid      int64
	token    string
	title    string
	category int
	rating   float64
	lang     string
	state    int
	label    string
	updater  string
	timeMS   int64
}

func writeFixture(t *testing.T, path string, rows []fixtureRow, labels []Label, dirnames map[int64]string) {
	t.Helper()

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	// modernc needs a plain writable DSN for fixture creation.
	db, err := sql.Open("sqlite", "file:"+filepath.ToSlash(path)+"?_pragma=journal_mode(DELETE)")
	if err != nil {
		t.Fatalf("open fixture: %v", err)
	}
	defer db.Close()

	for _, ddl := range []string{downloadsDDL, labelsDDL, dirnameDDL} {
		if _, err := db.Exec(ddl); err != nil {
			t.Fatalf("create table: %v", err)
		}
	}
	if _, err := db.Exec("PRAGMA user_version = 8"); err != nil {
		t.Fatalf("set user_version: %v", err)
	}

	for _, r := range rows {
		_, err := db.Exec(
			`INSERT INTO "DOWNLOADS"
			 (GID, TOKEN, TITLE, TITLE_JPN, THUMB, CATEGORY, POSTED, UPLOADER,
			  RATING, SIMPLE_LANGUAGE, STATE, LEGACY, TIME, LABEL, ARCHIVE_URI)
			 VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
			r.gid, r.token, r.title, "", "https://example.invalid/t.jpg",
			r.category, "2024-01-02 03:04", r.updater, r.rating, r.lang,
			r.state, 0, r.timeMS, r.label, nil,
		)
		if err != nil {
			t.Fatalf("insert download %d: %v", r.gid, err)
		}
	}
	for _, l := range labels {
		if _, err := db.Exec(
			`INSERT INTO "DOWNLOAD_LABELS" (ID, LABEL, TIME) VALUES (?,?,?)`,
			l.ID, l.Label, l.Time); err != nil {
			t.Fatalf("insert label: %v", err)
		}
	}
	for gid, name := range dirnames {
		if _, err := db.Exec(
			`INSERT INTO "DOWNLOAD_DIRNAME" (GID, DIRNAME) VALUES (?,?)`,
			gid, name); err != nil {
			t.Fatalf("insert dirname: %v", err)
		}
	}
}

func TestOpenReadsDownloads(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "20240101120000.db")
	writeFixture(t, path, []fixtureRow{
		{gid: 1234567, token: "abcd1234", title: "示例画集", category: 1, rating: 4.5,
			lang: "ZH", state: 3, label: "默认", updater: "someone", timeMS: 1700000000000},
	}, []Label{{ID: 1, Label: "默认", Time: 1600000000000}}, map[int64]string{1234567: "1234567-示例画集"})

	snap, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if snap.SchemaVersion != 8 {
		t.Errorf("schema version: got %d, want 8", snap.SchemaVersion)
	}
	if len(snap.Galleries) != 1 {
		t.Fatalf("galleries: got %d, want 1", len(snap.Galleries))
	}
	m := snap.Galleries[1234567]
	if m == nil {
		t.Fatal("gid 1234567 missing")
	}
	if m.Title != "示例画集" || m.Token != "abcd1234" {
		t.Errorf("unexpected title/token: %+v", *m)
	}
	if m.Category != 1 || m.Rating != 4.5 || m.State != 3 {
		t.Errorf("unexpected numeric fields: %+v", *m)
	}
	if m.SimpleLanguage != "ZH" || m.Label != "默认" || m.Uploader != "someone" {
		t.Errorf("unexpected text fields: %+v", *m)
	}
	if m.TimeMS != 1700000000000 {
		t.Errorf("time: got %d", m.TimeMS)
	}
	if got := snap.DirNames[1234567]; got != "1234567-示例画集" {
		t.Errorf("dirname: got %q", got)
	}
	if len(snap.Labels) != 1 || snap.Labels[0].Label != "默认" {
		t.Errorf("labels: %+v", snap.Labels)
	}
	if !snap.Present[TableDownloads] || !snap.Present[TableDownloadLabels] {
		t.Errorf("present tables: %+v", snap.Present)
	}
}

// A snapshot whose DOWNLOADS table lacks the required columns must be
// rejected, not silently misread.
func TestOpenRejectsMissingRequiredColumn(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "broken.db")
	db, err := sql.Open("sqlite", "file:"+filepath.ToSlash(path))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`CREATE TABLE "DOWNLOADS" ("GID" INTEGER PRIMARY KEY, "TOKEN" TEXT)`); err != nil {
		t.Fatal(err)
	}
	db.Close()

	_, err = Open(path)
	if err == nil {
		t.Fatal("expected an error for a DOWNLOADS table without TITLE")
	}
	if !strings.Contains(err.Error(), "TITLE") {
		t.Errorf("error should name the missing column, got: %v", err)
	}
}

// A file that is not SQLite at all (e.g. a partially synced transfer) must
// fail cleanly so the caller can skip it.
func TestOpenRejectsGarbage(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "half-synced.db")
	if err := os.WriteFile(path, []byte("this is not a database, Syncthing is mid-transfer"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(path); err == nil {
		t.Fatal("expected an error for a non-SQLite file")
	}
}

func TestListCandidatesNewestFirst(t *testing.T) {
	dir := t.TempDir()
	names := []string{"a.db", "b.db", "c.db"}
	base := time.Now().Add(-time.Hour)
	for i, n := range names {
		p := filepath.Join(dir, n)
		if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
		mt := base.Add(time.Duration(i) * time.Minute)
		if err := os.Chtimes(p, mt, mt); err != nil {
			t.Fatal(err)
		}
	}
	// Noise that must be ignored.
	if err := os.WriteFile(filepath.Join(dir, "a.db-wal"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	got, err := ListCandidates(dir)
	if err != nil {
		t.Fatalf("ListCandidates: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("got %d candidates, want 3: %+v", len(got), got)
	}
	if filepath.Base(got[0].Path) != "c.db" || filepath.Base(got[2].Path) != "a.db" {
		t.Errorf("wrong order: %s, %s, %s",
			filepath.Base(got[0].Path), filepath.Base(got[1].Path), filepath.Base(got[2].Path))
	}
}

func TestListCandidatesMissingDirIsNotAnError(t *testing.T) {
	got, err := ListCandidates(filepath.Join(t.TempDir(), "nope"))
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if len(got) != 0 {
		t.Errorf("expected no candidates, got %+v", got)
	}
}

// With PolicyMerge a row dropped from the newest export survives, and a row
// present in both takes the newest values.
func TestMergePolicySemantics(t *testing.T) {
	dir := t.TempDir()
	oldPath := filepath.Join(dir, "20240101000000.db")
	newPath := filepath.Join(dir, "20240202000000.db")

	writeFixture(t, oldPath, []fixtureRow{
		{gid: 1, title: "old one", state: 3},
		{gid: 2, title: "dropped later", state: 3},
	}, nil, nil)
	writeFixture(t, newPath, []fixtureRow{
		{gid: 1, title: "new one", state: 3},
	}, nil, nil)

	// Make the ordering unambiguous regardless of filesystem timestamp
	// granularity.
	older := time.Now().Add(-2 * time.Hour)
	newer := time.Now().Add(-1 * time.Hour)
	if err := os.Chtimes(oldPath, older, older); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(newPath, newer, newer); err != nil {
		t.Fatal(err)
	}

	cands, err := ListCandidates(dir)
	if err != nil {
		t.Fatal(err)
	}

	oldSnap, err := Open(oldPath)
	if err != nil {
		t.Fatal(err)
	}
	newSnap, err := Open(newPath)
	if err != nil {
		t.Fatal(err)
	}

	latest := Merge([]*Snapshot{oldSnap, newSnap}, PolicyLatest)
	if len(latest.Galleries) != 1 {
		t.Fatalf("latest: got %d galleries, want 1", len(latest.Galleries))
	}
	if got := latest.Galleries[1].Title; got != "new one" {
		t.Errorf("latest title: got %q, want %q", got, "new one")
	}

	merged := Merge([]*Snapshot{oldSnap, newSnap}, PolicyMerge)
	if len(merged.Galleries) != 2 {
		t.Fatalf("merge: got %d galleries, want 2", len(merged.Galleries))
	}
	if got := merged.Galleries[1].Title; got != "new one" {
		t.Errorf("merge must prefer the newer row, got %q", got)
	}
	if got := merged.Galleries[2].Title; got != "dropped later" {
		t.Errorf("merge must keep the older-only row, got %q", got)
	}

	// LoadAll must agree and must not report errors for healthy files.
	loaded, errs := LoadAll(cands, PolicyMerge)
	if len(errs) != 0 {
		t.Errorf("LoadAll reported errors: %v", errs)
	}
	if len(loaded.Galleries) != 2 {
		t.Errorf("LoadAll: got %d galleries, want 2", len(loaded.Galleries))
	}
}

func TestLoadAllSkipsUnreadableFile(t *testing.T) {
	dir := t.TempDir()
	goodPath := filepath.Join(dir, "good.db")
	badPath := filepath.Join(dir, "bad.db")
	writeFixture(t, goodPath, []fixtureRow{{gid: 7, title: "kept", state: 3}}, nil, nil)
	if err := os.WriteFile(badPath, []byte("garbage"), 0o644); err != nil {
		t.Fatal(err)
	}
	older := time.Now().Add(-2 * time.Hour)
	newer := time.Now().Add(-time.Hour)
	_ = os.Chtimes(goodPath, older, older)
	_ = os.Chtimes(badPath, newer, newer)

	cands, err := ListCandidates(dir)
	if err != nil {
		t.Fatal(err)
	}
	merged, errs := LoadAll(cands, PolicyMerge)
	if len(errs) != 1 {
		t.Errorf("expected exactly one error, got %v", errs)
	}
	if len(merged.Galleries) != 1 {
		t.Fatalf("expected the good snapshot to survive, got %d galleries", len(merged.Galleries))
	}
	if merged.Galleries[7] == nil {
		t.Error("gid 7 should be present")
	}
	// The newest file failed, so the authoritative timestamp must still come
	// from the newest *readable* snapshot.
	if merged.SourcePath != goodPath {
		t.Errorf("source path: got %q, want %q", merged.SourcePath, goodPath)
	}
}

func TestDSNIsReadOnlyURI(t *testing.T) {
	got := dsn(`C:\Users\Warren\Ehviewer Online\data\a.db`)
	for _, want := range []string{"mode=ro", "immutable=1", "_query_only=true", "file:///"} {
		if !strings.Contains(got, want) {
			t.Errorf("dsn %q is missing %q", got, want)
		}
	}
	if strings.Contains(got, `\`) {
		t.Errorf("dsn %q must not contain backslashes", got)
	}
}

func TestAsInt64Coercions(t *testing.T) {
	cases := []struct {
		in   any
		want int64
	}{
		{nil, 0},
		{int64(42), 42},
		{float64(42.9), 42},
		{"123", 123},
		{"-7", -7},
		{[]byte("99"), 99},
		{"not a number", 0},
		{true, 1},
	}
	for _, c := range cases {
		if got := asInt64(c.in); got != c.want {
			t.Errorf("asInt64(%#v) = %d, want %d", c.in, got, c.want)
		}
	}
}

func TestAsFloat64Coercions(t *testing.T) {
	cases := []struct {
		in   any
		want float64
	}{
		{nil, 0},
		{4.5, 4.5},
		{int64(3), 3},
		{"4.25", 4.25},
		{"abc", 0},
		{"", 0},
	}
	for _, c := range cases {
		if got := asFloat64(c.in); got != c.want {
			t.Errorf("asFloat64(%#v) = %v, want %v", c.in, got, c.want)
		}
	}
}
