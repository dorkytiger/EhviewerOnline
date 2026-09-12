// Package dbexport reads the SQLite snapshots that EhViewer's "export data"
// action writes into <root>/data/<timestamp>.db.
//
// What the export contains is fixed by EhDB.exportDB()
// (app/src/main/java/com/hippo/ehviewer/EhDB.java:913-976), which copies
// exactly eight tables:
//
//	DOWNLOADS, DOWNLOAD_LABELS, DOWNLOAD_DIRNAME, HISTORY,
//	QUICK_SEARCH, LOCAL_FAVORITES, BOOKMARKS, FILTER
//
// Gallery_Tags is NOT among them, so per-tag filtering is impossible from a
// snapshot alone. See the design doc §2.5.
//
// Snapshots are opened strictly read-only. Syncthing may be mid-transfer when
// we look at a file, so a failed open or a failed integrity check is an
// expected condition, not a bug: the caller skips that snapshot and keeps
// using the previous good one.
package dbexport

import (
	"database/sql"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	_ "modernc.org/sqlite" // database/sql driver
)

// Table names, as declared by @Entity(nameInDb = ...) on each DAO.
const (
	TableDownloads       = "DOWNLOADS"
	TableDownloadLabels  = "DOWNLOAD_LABELS"
	TableDownloadDirname = "DOWNLOAD_DIRNAME"
	TableHistory         = "HISTORY"
	TableLocalFavorites  = "LOCAL_FAVORITES"
)

// Meta is one DOWNLOADS row. Column names come from DownloadsDao.java:206-220.
type Meta struct {
	GID            int64
	Token          string
	Title          string
	TitleJpn       string
	Thumb          string
	Category       int
	Posted         string
	Uploader       string
	Rating         float64
	SimpleLanguage string
	State          int
	Legacy         int
	TimeMS         int64
	Label          string
	ArchiveURI     string
}

// Snapshot is a single parsed .db file. The zero value is not usable; use
// Open to build one.
type Snapshot struct {
	// Path is the file the snapshot came from.
	Path string
	// TakenAtMS is the file mtime: the best available proxy for "when the
	// phone exported this". Note this is when the file landed on disk, which
	// for a Syncthing transfer is when it finished syncing, not when the
	// export was made.
	TakenAtMS int64
	// SchemaVersion is PRAGMA user_version. DaoMaster.SCHEMA_VERSION is 8.
	SchemaVersion int
	// Galleries is keyed by gid.
	Galleries map[int64]*Meta
	// Labels is the DOWNLOAD_LABELS table in (id, label) insertion order.
	Labels []Label
	// DirNames maps gid -> directory name (DOWNLOAD_DIRNAME). Needed to
	// resolve a gallery whose directory was renamed by hand.
	DirNames map[int64]string
	// Present lists the tables that were found.
	Present map[string]bool
	// Warnings collects non-fatal oddities.
	Warnings []string
}

// Label is one DOWNLOAD_LABELS row (DownloadLabel.java).
type Label struct {
	ID    int64
	Label string
	Time  int64
}

// Candidate is a snapshot file discovered on disk.
type Candidate struct {
	Path    string
	Size    int64
	MTimeMS int64
}

// ListCandidates returns the *.db files in dir, newest first. A missing
// directory yields an empty slice, not an error: the export directory is
// optional.
func ListCandidates(dir string) ([]Candidate, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("dbexport: read %q: %w", dir, err)
	}
	out := make([]Candidate, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if !strings.EqualFold(filepath.Ext(name), ".db") {
			continue
		}
		if strings.HasSuffix(name, "-wal") || strings.HasSuffix(name, "-shm") {
			continue
		}
		fi, err := e.Info()
		if err != nil {
			continue
		}
		out = append(out, Candidate{
			Path:    filepath.Join(dir, name),
			Size:    fi.Size(),
			MTimeMS: fi.ModTime().UnixMilli(),
		})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].MTimeMS != out[j].MTimeMS {
			return out[i].MTimeMS > out[j].MTimeMS
		}
		return out[i].Path > out[j].Path
	})
	return out, nil
}

// Open reads one snapshot.
//
// The connection string uses mode=ro&immutable=1 so that SQLite neither
// writes to the file nor creates -wal/-shm siblings inside the synced tree,
// and so that it skips locking entirely.
func Open(path string) (*Snapshot, error) {
	fi, err := os.Stat(path)
	if err != nil {
		return nil, fmt.Errorf("dbexport: stat %q: %w", path, err)
	}

	db, err := sql.Open("sqlite", dsn(path))
	if err != nil {
		return nil, fmt.Errorf("dbexport: open %q: %w", path, err)
	}
	defer db.Close()

	// A one-connection pool keeps the read-only handle deterministic.
	db.SetMaxOpenConns(1)

	snap := &Snapshot{
		Path:      path,
		TakenAtMS: fi.ModTime().UnixMilli(),
		Galleries: map[int64]*Meta{},
		DirNames:  map[int64]string{},
		Present:   map[string]bool{},
	}

	// Reject a truncated or half-synced file early. integrity_check on a
	// large snapshot costs a full scan, so cap the work with quick_check.
	var check string
	if err := db.QueryRow("PRAGMA quick_check(1)").Scan(&check); err != nil {
		return nil, fmt.Errorf("dbexport: %q is not a readable database: %w", path, err)
	}
	if !strings.EqualFold(check, "ok") {
		return nil, fmt.Errorf("dbexport: %q failed quick_check: %s", path, check)
	}

	_ = db.QueryRow("PRAGMA user_version").Scan(&snap.SchemaVersion)

	cols, err := tableColumns(db, TableDownloads)
	if err != nil {
		return nil, fmt.Errorf("dbexport: %q has no %s table: %w", path, TableDownloads, err)
	}
	snap.Present[TableDownloads] = true
	if missing := requiredDownloadColumns(cols); len(missing) > 0 {
		return nil, fmt.Errorf("dbexport: %q is missing column(s) %s in %s",
			path, strings.Join(missing, ", "), TableDownloads)
	}

	if err := readDownloads(db, snap, cols); err != nil {
		return nil, fmt.Errorf("dbexport: read %s from %q: %w", TableDownloads, path, err)
	}
	if err := readLabels(db, snap); err != nil {
		return nil, fmt.Errorf("dbexport: read %s from %q: %w", TableDownloadLabels, path, err)
	}
	if err := readDirNames(db, snap); err != nil {
		return nil, fmt.Errorf("dbexport: read %s from %q: %w", TableDownloadDirname, path, err)
	}

	if snap.SchemaVersion != 0 && snap.SchemaVersion != 8 {
		snap.Warnings = append(snap.Warnings, fmt.Sprintf(
			"schema version %d differs from the known DaoMaster.SCHEMA_VERSION 8",
			snap.SchemaVersion))
	}
	return snap, nil
}

func dsn(path string) string {
	// Paths may contain spaces, quotes and non-ASCII, so always go through a
	// URI form. filepath.ToSlash keeps Windows backslashes out of the URI.
	p := filepath.ToSlash(path)
	if !strings.HasPrefix(p, "/") {
		p = "/" + p
	}
	u := url.URL{Scheme: "file", Path: p}
	q := u.Query()
	q.Set("mode", "ro")
	q.Set("immutable", "1")
	q.Set("_query_only", "true")
	u.RawQuery = q.Encode()
	return u.String()
}

func requiredDownloadColumns(cols []string) []string {
	// Only the columns we cannot work without. ARCHIVE_URI and LEGACY are
	// optional: exportDB only adds ARCHIVE_URI defensively (EhDB.java:917-922).
	required := []string{"GID", "TITLE"}
	have := make(map[string]bool, len(cols))
	for _, c := range cols {
		have[strings.ToUpper(c)] = true
	}
	var missing []string
	for _, r := range required {
		if !have[r] {
			missing = append(missing, r)
		}
	}
	return missing
}

func tableColumns(db *sql.DB, table string) ([]string, error) {
	rows, err := db.Query("PRAGMA table_info(" + quoteIdent(table) + ")")
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var cols []string
	for rows.Next() {
		var (
			cid     int
			name    string
			ctype   sql.NullString
			notnull int
			dflt    sql.NullString
			pk      int
		)
		if err := rows.Scan(&cid, &name, &ctype, &notnull, &dflt, &pk); err != nil {
			return nil, err
		}
		cols = append(cols, name)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(cols) == 0 {
		return nil, fmt.Errorf("table %s does not exist", table)
	}
	return cols, nil
}

func quoteIdent(s string) string {
	return `"` + strings.ReplaceAll(s, `"`, `""`) + `"`
}

func readDownloads(db *sql.DB, snap *Snapshot, cols []string) error {
	quoted := make([]string, len(cols))
	for i, c := range cols {
		quoted[i] = quoteIdent(c)
	}
	q := "SELECT " + strings.Join(quoted, ", ") + " FROM " + quoteIdent(TableDownloads)

	rows, err := db.Query(q)
	if err != nil {
		return err
	}
	defer rows.Close()

	for rows.Next() {
		raw := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range raw {
			ptrs[i] = &raw[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return err
		}

		m := &Meta{}
		for i, c := range cols {
			switch strings.ToUpper(c) {
			case "GID":
				m.GID = asInt64(raw[i])
			case "TOKEN":
				m.Token = asString(raw[i])
			case "TITLE":
				m.Title = asString(raw[i])
			case "TITLE_JPN":
				m.TitleJpn = asString(raw[i])
			case "THUMB":
				m.Thumb = asString(raw[i])
			case "CATEGORY":
				m.Category = int(asInt64(raw[i]))
			case "POSTED":
				m.Posted = asString(raw[i])
			case "UPLOADER":
				m.Uploader = asString(raw[i])
			case "RATING":
				m.Rating = asFloat64(raw[i])
			case "SIMPLE_LANGUAGE":
				m.SimpleLanguage = asString(raw[i])
			case "STATE":
				m.State = int(asInt64(raw[i]))
			case "LEGACY":
				m.Legacy = int(asInt64(raw[i]))
			case "TIME":
				m.TimeMS = asInt64(raw[i])
			case "LABEL":
				m.Label = asString(raw[i])
			case "ARCHIVE_URI":
				m.ArchiveURI = asString(raw[i])
			}
		}
		if m.GID == 0 {
			continue
		}
		snap.Galleries[m.GID] = m
	}
	return rows.Err()
}

func readLabels(db *sql.DB, snap *Snapshot) error {
	cols, err := tableColumns(db, TableDownloadLabels)
	if err != nil {
		return nil // optional table
	}
	snap.Present[TableDownloadLabels] = true

	hasID := hasColumn(cols, "ID")
	hasTime := hasColumn(cols, "TIME")
	sel := []string{quoteIdent("LABEL")}
	if hasID {
		sel = append(sel, quoteIdent("ID"))
	}
	if hasTime {
		sel = append(sel, quoteIdent("TIME"))
	}
	q := "SELECT " + strings.Join(sel, ", ") + " FROM " + quoteIdent(TableDownloadLabels) +
		" ORDER BY " + quoteIdent("LABEL")

	rows, err := db.Query(q)
	if err != nil {
		return err
	}
	defer rows.Close()

	for rows.Next() {
		var (
			label string
			id    int64
			ts    int64
		)
		dest := []any{&label}
		if hasID {
			dest = append(dest, &id)
		}
		if hasTime {
			dest = append(dest, &ts)
		}
		if err := rows.Scan(dest...); err != nil {
			return err
		}
		snap.Labels = append(snap.Labels, Label{ID: id, Label: label, Time: ts})
	}
	return rows.Err()
}

func readDirNames(db *sql.DB, snap *Snapshot) error {
	if _, err := tableColumns(db, TableDownloadDirname); err != nil {
		return nil // optional table
	}
	snap.Present[TableDownloadDirname] = true

	q := "SELECT " + quoteIdent("GID") + ", " + quoteIdent("DIRNAME") +
		" FROM " + quoteIdent(TableDownloadDirname)
	rows, err := db.Query(q)
	if err != nil {
		return err
	}
	defer rows.Close()

	for rows.Next() {
		var gid int64
		var name sql.NullString
		if err := rows.Scan(&gid, &name); err != nil {
			return err
		}
		if name.Valid && name.String != "" {
			snap.DirNames[gid] = name.String
		}
	}
	return rows.Err()
}

func hasColumn(cols []string, want string) bool {
	for _, c := range cols {
		if strings.EqualFold(c, want) {
			return true
		}
	}
	return false
}

// --- column value coercion -------------------------------------------------
//
// The schema is fixed by the generated DAOs, but defensive coercion costs
// little and turns a hard failure into a degraded field if a future version
// changes a column type.

func asString(v any) string {
	switch t := v.(type) {
	case nil:
		return ""
	case string:
		return t
	case []byte:
		return string(t)
	case int64:
		return fmt.Sprintf("%d", t)
	case float64:
		return fmt.Sprintf("%g", t)
	case bool:
		if t {
			return "1"
		}
		return "0"
	case time.Time:
		return t.Format("2006-01-02 15:04")
	default:
		return fmt.Sprintf("%v", t)
	}
}

func asInt64(v any) int64 {
	switch t := v.(type) {
	case nil:
		return 0
	case int64:
		return t
	case int:
		return int64(t)
	case float64:
		return int64(t)
	case bool:
		if t {
			return 1
		}
		return 0
	case []byte:
		return parseDecimal(string(t))
	case string:
		return parseDecimal(t)
	case time.Time:
		return t.UnixMilli()
	default:
		return 0
	}
}

func asFloat64(v any) float64 {
	switch t := v.(type) {
	case nil:
		return 0
	case float64:
		return t
	case int64:
		return float64(t)
	case int:
		return float64(t)
	case []byte:
		return parseFloat(string(t))
	case string:
		return parseFloat(t)
	default:
		return 0
	}
}

func parseDecimal(s string) int64 {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0
	}
	var n int64
	neg := false
	if s[0] == '+' || s[0] == '-' {
		neg = s[0] == '-'
		s = s[1:]
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return 0
		}
		n = n*10 + int64(s[i]-'0')
	}
	if neg {
		return -n
	}
	return n
}

func parseFloat(s string) float64 {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0
	}
	var (
		f      float64
		seen   bool
		neg    bool
		frac   float64 = 1
		inFrac bool
	)
	i := 0
	if s[0] == '+' || s[0] == '-' {
		neg = s[0] == '-'
		i = 1
	}
	for ; i < len(s); i++ {
		c := s[i]
		if c == '.' {
			if inFrac {
				return 0
			}
			inFrac = true
			continue
		}
		if c < '0' || c > '9' {
			return 0
		}
		seen = true
		if inFrac {
			frac /= 10
			f += float64(c-'0') * frac
		} else {
			f = f*10 + float64(c-'0')
		}
	}
	if !seen {
		return 0
	}
	if neg {
		return -f
	}
	return f
}
