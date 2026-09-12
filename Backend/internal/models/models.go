// Package models holds the domain types shared by the scanner, the index and
// the HTTP layer. Field tags on Gallery double as the JSON wire contract.
package models

// Availability describes how usable a gallery entry is on disk.
type Availability string

const (
	// AvailOK means the directory exists and every expected page was found.
	AvailOK Availability = "ok"
	// AvailDegraded means the directory is browsable but something is off,
	// e.g. the page count disagrees with .ehviewer. See Anomalies.
	AvailDegraded Availability = "degraded"
	// AvailMissing means the row exists in the exported DB but no matching
	// directory was found. Usually Syncthing has not caught up yet.
	AvailMissing Availability = "missing"
)

// Anomaly codes reported on a gallery.
const (
	// AnomalyPageCountMismatch: .ehviewer says N pages, disk holds M.
	AnomalyPageCountMismatch = "page_count_mismatch"
	// AnomalyPageGap: page numbers are not contiguous starting at 0.
	AnomalyPageGap = "page_gap"
	// AnomalyEmptyGallery: the directory holds no recognizable image.
	AnomalyEmptyGallery = "empty_gallery"
	// AnomalyGIDMismatch: directory prefix and .ehviewer disagree on gid.
	AnomalyGIDMismatch = "gid_mismatch"
	// AnomalyDirUnparsable: the directory name does not look like <gid>-<title>.
	AnomalyDirUnparsable = "dir_unparsable"
	// AnomalySpiderInfoInvalid: .ehviewer exists but could not be parsed.
	AnomalySpiderInfoInvalid = "spiderinfo_invalid"
	// AnomalySpiderInfoMissing: no .ehviewer at all. The gallery is still fully
	// browsable (gid comes from the directory name and pages from the files),
	// but the token and the declared page count are unknown.
	AnomalySpiderInfoMissing = "spiderinfo_missing"
)

// TitleSource records where the display title came from.
const (
	TitleSourceDB      = "db"
	TitleSourceDirname = "dirname"
)

// SLangCodes are the ISO-ish language codes that GalleryInfo.generateSLang
// can produce, in the exact order of GalleryInfo.S_LANGS/S_LANG_PATTERNS
// (GalleryInfo.java:55-88). The order is load-bearing: the first matching
// pattern wins.
var SLangCodes = []string{
	"EN", // english pattern
	"ZH", // chinese pattern
	"ES", // spanish
	"KO", // korean
	"RU", // russian
	"FR", // french
	"PT", // portuguese
	"TH", // thai
	"DE", // german
	"IT", // italian
	"VI", // vietnamese
	"PL", // polish
	"HU", // hungarian
	"NL", // dutch
}

// MetaSource records how much metadata the entry has.
const (
	MetaSourceDB        = "db"         // merged with an exported DB snapshot
	MetaSourceLocalOnly = "local_only" // scanned from disk only
	MetaSourceOrphan    = "orphan_db"  // DB row without a directory on disk
)

// Page is a single image inside a gallery directory.
//
// Note that the on-disk index is 0-based while the filename is 1-based:
// SpiderDen.generateImageFilename formats "%08d" with index+1.
type Page struct {
	Index    int    `json:"index"`
	Filename string `json:"filename"`
	Ext      string `json:"ext"`
	Size     int64  `json:"size"`
	MTimeMS  int64  `json:"mtime_ms"`
	URL      string `json:"url"`
}

// SpiderInfo mirrors the subset of .ehviewer that this service needs.
// pTokenMap is deliberately not parsed: it only matters for resuming
// downloads on the phone.
type SpiderInfo struct {
	Version        int    `json:"version"`
	StartPage      int    `json:"start_page"`
	GID            int64  `json:"gid"`
	Token          string `json:"token"`
	PreviewPages   int    `json:"preview_pages"`
	PreviewPerPage int    `json:"preview_per_page"`
	Pages          int    `json:"pages"`
}

// Gallery is one entry in the index. It is the union of what the filesystem
// says and what the exported DB says; either side may be absent.
type Gallery struct {
	GID         int64  `json:"gid"`
	Token       string `json:"token,omitempty"`
	Title       string `json:"title"`
	TitleJpn    string `json:"title_jpn,omitempty"`
	TitleSource string `json:"title_source"`

	// DirPath is the absolute path of the gallery directory. Required to
	// serve images; never derived from user input (see httpapi).
	DirPath string `json:"-"`
	DirName string `json:"dir_name,omitempty"`

	// Artists, Groups, Series, Events and Editions are parsed from the
	// directory name, not read from a snapshot. The synced tree carries no tag
	// data at all — the export does not include Gallery_Tags, and Syncthing
	// syncs files rather than the phone's database — so the site's title
	// convention is the only tag source available, and these are the only
	// filterable dimensions that survive a library with no exported DB.
	//
	// They are heuristics over a string the site never promised to format
	// consistently (see scan.ParseDirTags) and are therefore advisory: a
	// client may show them, but must not treat a missing value as proof of
	// anything.
	Artists  []string `json:"artists,omitempty"`
	Groups   []string `json:"groups,omitempty"`
	Series   []string `json:"series,omitempty"`
	Events   []string `json:"events,omitempty"`
	Editions []string `json:"editions,omitempty"`

	Category       int     `json:"category"`
	Posted         string  `json:"posted,omitempty"`
	Uploader       string  `json:"uploader,omitempty"`
	Rating         float64 `json:"rating"`
	SimpleLanguage string  `json:"simple_language,omitempty"`
	Label          string  `json:"label,omitempty"`
	State          int     `json:"state"`

	// TimeMS is DOWNLOADS.TIME: when the gallery was added to downloads.
	TimeMS int64 `json:"download_time_ms"`

	// Thumb is the online thumbnail URL stored in the DB. It is a fallback
	// only: this service prefers the local image cache or page 1.
	Thumb string `json:"-"`

	// OnDisk is false for a DB row with no directory on disk.
	OnDisk bool `json:"on_disk"`

	PagesExpected int   `json:"pages_expected"`
	PagesFound    int   `json:"pages_found"`
	TotalBytes    int64 `json:"total_bytes"`

	CoverURL     string       `json:"cover_url"`
	CoverKind    string       `json:"cover_kind"`
	Availability Availability `json:"availability"`
	Anomalies    []string     `json:"anomalies"`
	MetaSource   string       `json:"meta_source"`

	// Not serialized: needed to compute cover versions and page URLs.
	MaxMTimeMS int64  `json:"-"`
	Pages      []Page `json:"pages,omitempty"`

	// Spider is the parsed .ehviewer header, when the file was present and
	// valid. Nil means "no usable metadata file", which is reported to the
	// client as spider_info.present = false rather than being invented.
	Spider *SpiderInfo `json:"-"`
}

// FacetValue is one bucket of a filter facet.
type FacetValue struct {
	Value string `json:"value"`
	Label string `json:"label,omitempty"`
	Count int    `json:"count"`
}

// Facets aggregates the filterable dimensions across the whole index.
//
// Every dimension is a list of buckets with counts, and every list is always
// present: an empty one means "nothing in this library carries this dimension",
// which is how a client tells a filter it should hide from one that would
// return nothing. The first five come from a DB snapshot and are empty without
// one; the last five are derived from directory names and survive a library
// that has never been exported.
type Facets struct {
	Labels       []FacetValue `json:"labels"`
	Languages    []FacetValue `json:"languages"`
	Categories   []FacetValue `json:"categories"`
	Availability []FacetValue `json:"availability"`

	Artists  []FacetValue `json:"artists"`
	Groups   []FacetValue `json:"groups"`
	Series   []FacetValue `json:"series"`
	Events   []FacetValue `json:"events"`
	Editions []FacetValue `json:"editions"`
}

// Query is a normalized gallery query.
//
// Label, Language, Category and Availability hold a single value because the
// snapshot supplies exactly one per gallery. The tag dimensions hold a list:
// a gallery can belong to several artists or be released by several groups,
// and a user picking two of them means "either", which is the only reading
// that does not silently make the result set smaller than what was asked for.
type Query struct {
	Text         string
	Label        string
	Language     string
	Category     *int
	Availability string
	Artists      []string
	Groups       []string
	Series       []string
	Events       []string
	Editions     []string
	Sort         string
	Limit        int
	Offset       int
}

// QueryResult is a page of gallery results.
type QueryResult struct {
	Items []*Gallery
	Total int
}
