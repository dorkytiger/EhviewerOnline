// Package index merges what the filesystem says with what the exported DB
// snapshot says, and answers queries over the result.
//
// The merge rules are described in the design doc §4.4. The important ones:
//
//   - The DB snapshot supplies metadata, the filesystem supplies facts about
//     pages. Neither is authoritative for the other's domain.
//   - A DB row with no directory on disk is still returned, marked
//     "missing". It usually means Syncthing has not caught up yet, so hiding
//     it would look like data loss.
//   - A directory with no DB row is returned as "local_only" with the title
//     taken from the directory name.
//
// The index is built whole and swapped in atomically. Galleries are treated as
// immutable after construction, so readers never need a lock.
package index

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/warren/ehviewer-webd/internal/dbexport"
	"github.com/warren/ehviewer-webd/internal/models"
	"github.com/warren/ehviewer-webd/internal/scan"
)

// randUint32 is indirected so a future deterministic mode can stub it.
func randUint32() uint32 { return rand.Uint32() }

// Sort keys accepted by Query.Sort.
const (
	SortTimeDesc   = "time_desc"
	SortTimeAsc    = "time_asc"
	SortTitleAsc   = "title"
	SortRatingDesc = "rating_desc"
	SortPagesDesc  = "pages_desc"
	SortGIDDesc    = "gid_desc"
	SortRandom     = "random"
)

// DefaultLimit is the page size when a query does not specify one.
const DefaultLimit = 60

// MaxLimit caps a caller-supplied limit.
const MaxLimit = 500

// Stats summarizes one build.
type Stats struct {
	Galleries     int    `json:"galleries"`
	OnDisk        int    `json:"on_disk"`
	Missing       int    `json:"missing"`
	Degraded      int    `json:"degraded"`
	Anomalies     int    `json:"anomalies"`
	Pages         int    `json:"pages"`
	TotalBytes    int64  `json:"total_bytes"`
	SkippedDirs   int    `json:"skipped_dirs"`
	SnapshotAtMS  int64  `json:"snapshot_at_ms"`
	SnapshotPath  string `json:"snapshot_path,omitempty"`
	SnapshotCount int    `json:"snapshot_count"`
	IndexedAtMS   int64  `json:"indexed_at_ms"`
	BuildMillis   int64  `json:"build_ms"`
}

// Index is an immutable snapshot of the merged view.
type Index struct {
	galleries []*models.Gallery
	byGID     map[int64]*models.Gallery
	facets    models.Facets
	stats     Stats
	warnings  []string
	skipped   []scan.Skip
}

// BuildInput is everything Build needs.
type BuildInput struct {
	// Scanned is the result of walking the download root.
	Scanned *scan.Result
	// Merged is the metadata from the exported DB snapshots. May be nil when
	// no snapshot is available; the index then runs in local-only mode.
	Merged *dbexport.Merged
	// DBErrors collects snapshots that could not be read, for reporting.
	DBErrors []error
	// Now is injected for deterministic tests. Zero means time.Now.
	Now func() time.Time
}

// Build merges a scan result with a DB snapshot into a new Index.
func Build(in BuildInput) *Index {
	started := time.Now()
	now := in.Now
	if now == nil {
		now = time.Now
	}

	idx := &Index{
		byGID: map[int64]*models.Gallery{},
	}

	if in.Scanned != nil {
		for _, g := range in.Scanned.Galleries {
			if g == nil {
				continue
			}
			g.OnDisk = true
			if g.Anomalies == nil {
				g.Anomalies = []string{}
			}
			// Derive the language from the title even without a snapshot.
			//
			// Dirname-derived titles carry the same markers as DB titles —
			// "[Chinese]", "[English]", 漢化 — because the directory name is
			// built from that same title. Restricting the derivation to DB rows
			// meant a library with no exported snapshot reported no language at
			// all, losing a filter the UI can otherwise offer for free.
			if g.SimpleLanguage == "" {
				g.SimpleLanguage = languageFromTitle(g.Title)
			}
			g.CoverKind, g.CoverURL = coverFor(g)
			idx.byGID[g.GID] = g
		}
		idx.skipped = in.Scanned.Skipped
	}

	if in.Merged != nil {
		mergeMetadata(idx, in.Merged)
		idx.stats.SnapshotAtMS = in.Merged.TakenAtMS
		idx.stats.SnapshotPath = in.Merged.SourcePath
		idx.stats.SnapshotCount = in.Merged.SnapshotCount
		idx.warnings = append(idx.warnings, in.Merged.Warnings...)
	} else {
		idx.warnings = append(idx.warnings,
			"no exported DB snapshot was found; titles come from directory names and "+
				"category/rating/label are unavailable (see the design doc §2.5)")
	}
	for _, err := range in.DBErrors {
		idx.warnings = append(idx.warnings, "snapshot skipped: "+err.Error())
	}

	// Directory-derived tags, and the display title for galleries whose title
	// has no other source.
	//
	// This runs after the merge deliberately, for two reasons. A snapshot title
	// is the site's own value and must not be rewritten. And languageFromTitle
	// — called above for scanned galleries and again in applyMeta — matches the
	// raw brackets ("[Chinese]", "漢化"), so cleaning a title before it ran
	// would silently drop the language facet for every gallery in the library.
	for _, g := range idx.byGID {
		raw, ok := dirTitleOf(g)
		if !ok {
			continue
		}
		tags := scan.ParseDirTags(raw)
		g.Artists, g.Groups, g.Series, g.Events, g.Editions =
			tags.Artists, tags.Groups, tags.Series, tags.Events, tags.Editions
		// Only a title that came from the directory name is cleaned: a
		// snapshot title is authoritative, and the raw name stays available in
		// dir_name either way.
		if g.TitleSource == models.TitleSourceDirname && tags.Title != "" {
			g.Title = tags.Title
		}
	}

	// Materialize in a deterministic order before storing.
	idx.galleries = make([]*models.Gallery, 0, len(idx.byGID))
	for _, g := range idx.byGID {
		idx.galleries = append(idx.galleries, g)
	}
	sort.Slice(idx.galleries, func(i, j int) bool {
		return idx.galleries[i].GID < idx.galleries[j].GID
	})

	idx.facets = buildFacets(idx.galleries)
	idx.stats = idx.computeStats(started, now)
	return idx
}

// dirTitleOf returns the title part of a gallery's directory name.
//
// ok is false when there is no directory to read. A DB row whose directory has
// not synced yet has no name, and its title comes from the snapshot rather than
// from a filename, so there is nothing to parse tags out of.
func dirTitleOf(g *models.Gallery) (string, bool) {
	if g.DirName == "" {
		return "", false
	}
	if _, title, ok := scan.ParseDirName(g.DirName); ok {
		return title, true
	}
	// Not a "<gid>-<title>" name. Whatever it is, it is the only title
	// available, so the tags are read from it as-is.
	return g.DirName, true
}

// mergeMetadata layers DB rows over the scanned galleries, adding orphan rows
// for DB entries with no directory.
func mergeMetadata(idx *Index, merged *dbexport.Merged) {
	for gid, meta := range merged.Galleries {
		if g, ok := idx.byGID[gid]; ok {
			applyMeta(g, meta)
			continue
		}
		// An orphan row. DOWNLOAD_DIRNAME may still tell us the directory
		// name, but the directory itself is absent.
		g := &models.Gallery{
			GID:          gid,
			DirName:      merged.DirNames[gid],
			OnDisk:       false,
			Availability: models.AvailMissing,
			MetaSource:   models.MetaSourceOrphan,
			Anomalies:    []string{},
			CoverKind:    "none",
		}
		applyMeta(g, meta)
		if g.Title == "" {
			// No title anywhere: the gid is all we have.
			g.Title = strconv.FormatInt(gid, 10)
			g.TitleSource = models.TitleSourceDirname
		}
		g.CoverKind, g.CoverURL = coverFor(g)
		idx.byGID[gid] = g
	}
}

// applyMeta copies DB fields onto a gallery. The DB always wins for metadata;
// the filesystem always wins for page facts.
func applyMeta(g *models.Gallery, meta *dbexport.Meta) {
	if meta.Title != "" {
		g.Title = meta.Title
		g.TitleSource = models.TitleSourceDB
	}
	g.TitleJpn = meta.TitleJpn
	if meta.Token != "" {
		g.Token = meta.Token
	}
	g.Category = meta.Category
	g.Posted = meta.Posted
	g.Uploader = meta.Uploader
	g.Rating = meta.Rating
	g.Label = meta.Label
	g.State = meta.State
	g.TimeMS = meta.TimeMS
	g.Thumb = meta.Thumb
	if meta.SimpleLanguage != "" {
		g.SimpleLanguage = meta.SimpleLanguage
	} else {
		// SIMPLE_LANGUAGE is derived from tags on the phone, and tags are not
		// in the export, so it is frequently NULL. Fall back to the title.
		g.SimpleLanguage = languageFromTitle(g.Title)
	}
	if g.MetaSource == "" || g.MetaSource == models.MetaSourceLocalOnly {
		g.MetaSource = models.MetaSourceDB
	}
}

// languageFromTitle is a direct port of GalleryInfo.generateSLangFromTitle
// (GalleryInfo.java:217-225) using S_LANG_PATTERNS (lines 72-88).
//
// Order matters: the patterns are tried in declaration order and the first
// match wins, so ZH is only reported when EN did not match first. The Go
// regexp syntax used here matches the Java patterns closely enough for these
// particular expressions, except that Go's \b and character classes behave the
// same way; the only rewrite needed is that Java's "[(\\[]" is just "[(\\[]".
func languageFromTitle(title string) string {
	for i, re := range langPatterns {
		if re.MatchString(title) {
			return models.SLangCodes[i]
		}
	}
	return ""
}

// coverFor derives the cover reference. Page 1 is the source; the HTTP layer
// may swap in an image-cache thumbnail when one exists.
func coverFor(g *models.Gallery) (kind, url string) {
	if len(g.Pages) == 0 {
		if g.Thumb != "" {
			return "remote", g.Thumb
		}
		return "none", ""
	}
	v := g.MaxMTimeMS
	if v == 0 {
		v = g.TimeMS
	}
	return "firstpage", fmt.Sprintf("/thumb/%d?v=%d", g.GID, v)
}

func (idx *Index) computeStats(started time.Time, now func() time.Time) Stats {
	s := Stats{
		Galleries:    len(idx.galleries),
		SkippedDirs:  len(idx.skipped),
		IndexedAtMS:  now().UnixMilli(),
		BuildMillis:  time.Since(started).Milliseconds(),
		SnapshotAtMS: idx.stats.SnapshotAtMS,
	}
	s.SnapshotPath = idx.stats.SnapshotPath
	s.SnapshotCount = idx.stats.SnapshotCount
	for _, g := range idx.galleries {
		if g.OnDisk {
			s.OnDisk++
		} else {
			s.Missing++
		}
		switch g.Availability {
		case models.AvailDegraded:
			s.Degraded++
		case models.AvailMissing:
			if g.OnDisk {
				s.Degraded++ // on disk but unusable (empty or unreadable)
			}
		}
		if len(g.Anomalies) > 0 {
			s.Anomalies++
		}
		s.Pages += g.PagesFound
		s.TotalBytes += g.TotalBytes
	}
	return s
}

// --- read access -----------------------------------------------------------

// Stats returns build statistics.
func (idx *Index) Stats() Stats { return idx.stats }

// Warnings returns build-time warnings.
func (idx *Index) Warnings() []string { return idx.warnings }

// Skipped returns directories left out of the index.
func (idx *Index) Skipped() []scan.Skip { return idx.skipped }

// Facets returns the aggregated filter dimensions.
func (idx *Index) Facets() models.Facets { return idx.facets }

// Len returns the number of galleries.
func (idx *Index) Len() int { return len(idx.galleries) }

// Get looks a gallery up by gid.
func (idx *Index) Get(gid int64) (*models.Gallery, bool) {
	g, ok := idx.byGID[gid]
	return g, ok
}

// All returns every gallery. The slice must not be mutated.
func (idx *Index) All() []*models.Gallery { return idx.galleries }

// Query applies filters, sorting and pagination.
func (idx *Index) Query(q models.Query) models.QueryResult {
	limit := q.Limit
	if limit <= 0 {
		limit = DefaultLimit
	}
	if limit > MaxLimit {
		limit = MaxLimit
	}

	filtered := make([]*models.Gallery, 0, len(idx.galleries))
	for _, g := range idx.galleries {
		if !matches(g, q) {
			continue
		}
		filtered = append(filtered, g)
	}
	sortGalleries(filtered, q.Sort)

	total := len(filtered)
	offset := q.Offset
	if offset < 0 {
		offset = 0
	}
	if offset >= total {
		return models.QueryResult{Items: []*models.Gallery{}, Total: total}
	}
	end := offset + limit
	if end > total {
		end = total
	}
	return models.QueryResult{Items: filtered[offset:end], Total: total}
}

func matches(g *models.Gallery, q models.Query) bool {
	if q.Label != "" && g.Label != q.Label {
		return false
	}
	if q.Language != "" && !strings.EqualFold(g.SimpleLanguage, q.Language) {
		return false
	}
	if q.Category != nil && g.Category != *q.Category {
		return false
	}
	if q.Availability != "" && string(g.Availability) != q.Availability {
		return false
	}
	if !matchesAnyTag(g.Artists, q.Artists) ||
		!matchesAnyTag(g.Groups, q.Groups) ||
		!matchesAnyTag(g.Series, q.Series) ||
		!matchesAnyTag(g.Events, q.Events) ||
		!matchesAnyTag(g.Editions, q.Editions) {
		return false
	}
	if q.Text != "" && !matchesText(g, q.Text) {
		return false
	}
	return true
}

// matchesAnyTag reports whether a gallery carries at least one of the requested
// tags.
//
// Within a dimension the values are OR-ed: picking two scanlation groups means
// "either of these", which is what a filter list implies. Requiring both would
// silently return only galleries that two groups happen to share, which is
// almost always the empty set. Dimensions are still AND-ed with each other.
//
// The comparison folds case because the library contains the same artist
// spelled two ways — "Koukyuu Denim..." and "Koukyuu denim..." — and a filter
// built from one facet label must match the other.
func matchesAnyTag(have, want []string) bool {
	if len(want) == 0 {
		return true
	}
	for _, w := range want {
		for _, h := range have {
			if strings.EqualFold(h, w) {
				return true
			}
		}
	}
	return false
}

// matchesText is a case-insensitive substring search over the fields a user
// would search by. It is deliberately simple: at the scale this service
// targets (thousands of galleries) a linear scan is far cheaper than
// maintaining an FTS index, and it avoids the two-index consistency problem.
func matchesText(g *models.Gallery, needle string) bool {
	needle = strings.ToLower(strings.TrimSpace(needle))
	if needle == "" {
		return true
	}
	for _, field := range []string{g.Title, g.TitleJpn, g.Uploader, g.Label, g.Token} {
		if field == "" {
			continue
		}
		if strings.Contains(strings.ToLower(field), needle) {
			return true
		}
	}
	// The derived tags are searchable too: a user typing a scanlation group or
	// a parody into the search box is asking the same question the filter list
	// asks, and making them use the other control to get an answer would be
	// arbitrary.
	for _, tags := range [][]string{g.Artists, g.Groups, g.Series, g.Events, g.Editions} {
		for _, tag := range tags {
			if strings.Contains(strings.ToLower(tag), needle) {
				return true
			}
		}
	}
	return strings.Contains(strconv.FormatInt(g.GID, 10), needle)
}

func sortGalleries(gs []*models.Gallery, key string) {
	switch key {
	case SortTimeAsc:
		sort.SliceStable(gs, func(i, j int) bool { return lessTime(gs[i], gs[j], true) })
	case SortTitleAsc:
		sort.SliceStable(gs, func(i, j int) bool {
			a, b := strings.ToLower(gs[i].Title), strings.ToLower(gs[j].Title)
			if a != b {
				return a < b
			}
			return gs[i].GID < gs[j].GID
		})
	case SortRatingDesc:
		sort.SliceStable(gs, func(i, j int) bool {
			if gs[i].Rating != gs[j].Rating {
				return gs[i].Rating > gs[j].Rating
			}
			return lessTime(gs[i], gs[j], false)
		})
	case SortPagesDesc:
		sort.SliceStable(gs, func(i, j int) bool {
			if gs[i].PagesFound != gs[j].PagesFound {
				return gs[i].PagesFound > gs[j].PagesFound
			}
			return lessTime(gs[i], gs[j], false)
		})
	case SortGIDDesc:
		sort.SliceStable(gs, func(i, j int) bool { return gs[i].GID > gs[j].GID })
	case SortRandom:
		// Shuffle is stable per-process only; callers wanting reproducibility
		// should not use this key.
		for i := len(gs) - 1; i > 0; i-- {
			j := int(randUint32()) % (i + 1)
			gs[i], gs[j] = gs[j], gs[i]
		}
	case SortTimeDesc:
		fallthrough
	default:
		sort.SliceStable(gs, func(i, j int) bool { return lessTime(gs[i], gs[j], false) })
	}
}

func lessTime(a, b *models.Gallery, asc bool) bool {
	if a.TimeMS != b.TimeMS {
		if asc {
			return a.TimeMS < b.TimeMS
		}
		return a.TimeMS > b.TimeMS
	}
	// Galleries with no DB row have TimeMS 0; fall back to file mtime so they
	// do not all clump at the bottom.
	am, bm := a.MaxMTimeMS, b.MaxMTimeMS
	if am != bm {
		if asc {
			return am < bm
		}
		return am > bm
	}
	if asc {
		return a.GID < b.GID
	}
	return a.GID > b.GID
}

func buildFacets(gs []*models.Gallery) models.Facets {
	labels := map[string]int{}
	langs := map[string]int{}
	cats := map[int]int{}
	avail := map[string]int{}
	artists := tagCounter{}
	groups := tagCounter{}
	series := tagCounter{}
	events := tagCounter{}
	editions := tagCounter{}

	for _, g := range gs {
		if g.Label != "" {
			labels[g.Label]++
		}
		if g.SimpleLanguage != "" {
			langs[g.SimpleLanguage]++
		}
		cats[g.Category]++
		avail[string(g.Availability)]++

		artists.add(g.Artists)
		groups.add(g.Groups)
		series.add(g.Series)
		events.add(g.Events)
		editions.add(g.Editions)
	}

	f := models.Facets{
		Labels:       toFacetValues(labels),
		Languages:    toFacetValues(langs),
		Categories:   toFacetValuesInt(cats),
		Availability: toFacetValues(avail),
		Artists:      artists.facetValues(),
		Groups:       groups.facetValues(),
		Series:       series.facetValues(),
		Events:       events.facetValues(),
		Editions:     editions.facetValues(),
	}
	return f
}

// tagCounter counts a tag dimension, folding spellings that differ only in
// case.
//
// Folding matters because the library really does contain both "Koukyuu Denim
// ni wa Shichimi o Kakenaide (Futee)" and its all-lowercase spelling for one
// artist. Counting them as two entries splits a filter the user thinks of as
// one, and picking either half would hide the other half's galleries.
//
// The label keeps a spelling the library actually uses rather than the folded
// key, so the filter list reads like the directory names instead of like a
// normalised database column.
type tagCounter map[string]map[string]int

func (c tagCounter) add(values []string) {
	for _, v := range values {
		v = strings.TrimSpace(v)
		if v == "" {
			continue
		}
		key := strings.ToLower(v)
		if c[key] == nil {
			c[key] = map[string]int{}
		}
		c[key][v]++
	}
}

// facetValues returns the buckets, most used first. Ties break on the folded
// key so the order does not depend on map iteration.
//
// The label is the most frequent spelling, ties broken alphabetically. Both
// choices are order-independent on purpose: the same library must produce the
// same facets on every rebuild, or a client diffing two responses would see
// churn in a list nothing changed.
func (c tagCounter) facetValues() []models.FacetValue {
	out := make([]models.FacetValue, 0, len(c))
	for key, spellings := range c {
		total, best, label := 0, -1, ""
		for spelling, n := range spellings {
			total += n
			if n > best || (n == best && spelling < label) {
				best, label = n, spelling
			}
		}
		out = append(out, models.FacetValue{Value: key, Label: label, Count: total})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Count != out[j].Count {
			return out[i].Count > out[j].Count
		}
		return out[i].Value < out[j].Value
	})
	return out
}

func toFacetValues(m map[string]int) []models.FacetValue {
	out := make([]models.FacetValue, 0, len(m))
	for k, v := range m {
		out = append(out, models.FacetValue{Value: k, Count: v})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Count != out[j].Count {
			return out[i].Count > out[j].Count
		}
		return out[i].Value < out[j].Value
	})
	return out
}

func toFacetValuesInt(m map[int]int) []models.FacetValue {
	out := make([]models.FacetValue, 0, len(m))
	for k, v := range m {
		out = append(out, models.FacetValue{Value: strconv.Itoa(k), Count: v})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Count != out[j].Count {
			return out[i].Count > out[j].Count
		}
		return out[i].Value < out[j].Value
	})
	return out
}

// --- cursor paging ---------------------------------------------------------

// Cursor is the opaque pagination token. It carries the offset and a hash of
// the filter set, so a cursor cannot be replayed against a different query and
// silently skip or repeat rows.
type Cursor struct {
	Offset int    `json:"o"`
	Filter string `json:"f"`
}

// EncodeCursor renders a cursor as URL-safe base64.
func EncodeCursor(offset int, filter string) string {
	b, err := json.Marshal(Cursor{Offset: offset, Filter: filter})
	if err != nil {
		return ""
	}
	return base64.RawURLEncoding.EncodeToString(b)
}

// DecodeCursor parses a cursor and verifies it belongs to filter.
func DecodeCursor(s, filter string) (int, error) {
	if s == "" {
		return 0, nil
	}
	raw, err := base64.RawURLEncoding.DecodeString(s)
	if err != nil {
		return 0, fmt.Errorf("index: malformed cursor: %w", err)
	}
	var c Cursor
	if err := json.Unmarshal(raw, &c); err != nil {
		return 0, fmt.Errorf("index: malformed cursor: %w", err)
	}
	if c.Filter != filter {
		return 0, fmt.Errorf("index: cursor belongs to a different query")
	}
	if c.Offset < 0 {
		return 0, fmt.Errorf("index: cursor has a negative offset")
	}
	return c.Offset, nil
}

// FilterFingerprint builds the stable string a cursor is bound to.
//
// The tag lists are folded and sorted before they are joined, so that the same
// filter expressed in a different order — which two clients, or two renders of
// one UI, will happily produce — still yields the same fingerprint. Without
// that, paging would reject its own cursor as belonging to a different query
// and the list would stop dead at the first page boundary.
func FilterFingerprint(q models.Query) string {
	cat := ""
	if q.Category != nil {
		cat = strconv.Itoa(*q.Category)
	}
	parts := []string{q.Text, q.Label, q.Language, cat, q.Availability, q.Sort}
	for _, tags := range [][]string{q.Artists, q.Groups, q.Series, q.Events, q.Editions} {
		folded := make([]string, 0, len(tags))
		for _, t := range tags {
			folded = append(folded, strings.ToLower(t))
		}
		sort.Strings(folded)
		parts = append(parts, strings.Join(folded, "\x1e"))
	}
	return strings.Join(parts, "\x1f")
}

// --- atomic holder ---------------------------------------------------------

// Store holds the current index and lets the watcher swap it in.
type Store struct {
	v atomic.Pointer[Index]
}

// NewStore wraps an index.
func NewStore(idx *Index) *Store {
	s := &Store{}
	s.v.Store(idx)
	return s
}

// Load returns the current index. Never nil once constructed.
func (s *Store) Load() *Index { return s.v.Load() }

// Swap replaces the current index atomically.
func (s *Store) Swap(idx *Index) { s.v.Store(idx) }
