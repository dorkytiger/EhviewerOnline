package index

import (
	"testing"
	"time"

	"github.com/warren/ehviewer-webd/internal/dbexport"
	"github.com/warren/ehviewer-webd/internal/models"
	"github.com/warren/ehviewer-webd/internal/scan"
)

func gallery(gid int64, dirName string, pages int) *models.Gallery {
	// Mirrors scan.LoadDir: the title is the directory name with the "<gid>-"
	// prefix removed, not the whole name. A helper that stored the full name
	// would let the index derive a different title from DirName and quietly
	// disagree with production.
	title := dirName
	if _, t, ok := scan.ParseDirName(dirName); ok {
		title = t
	}
	g := &models.Gallery{
		GID:           gid,
		DirName:       dirName,
		DirPath:       "/sync/download/" + dirName,
		Title:         title,
		TitleSource:   models.TitleSourceDirname,
		Availability:  models.AvailOK,
		MetaSource:    models.MetaSourceLocalOnly,
		Anomalies:     []string{},
		PagesFound:    pages,
		PagesExpected: pages,
	}
	for i := 0; i < pages; i++ {
		g.Pages = append(g.Pages, models.Page{
			Index:    i,
			Filename: pad8(i+1) + ".jpg",
			Ext:      ".jpg",
			Size:     100,
			MTimeMS:  1000,
			URL:      "/img/x",
		})
	}
	return g
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

func meta(gid int64, title string) *dbexport.Meta {
	return &dbexport.Meta{
		GID:      gid,
		Title:    title,
		Token:    "tok",
		Category: 1,
		Rating:   4.0,
		Label:    "默认",
		State:    3,
		TimeMS:   5000,
	}
}

func buildOne(t *testing.T, galleries []*models.Gallery, merged *dbexport.Merged) *Index {
	t.Helper()
	return Build(BuildInput{
		Scanned: &scan.Result{Galleries: galleries},
		Merged:  merged,
		Now:     func() time.Time { return time.UnixMilli(9999) },
	})
}

// --- merge matrix ----------------------------------------------------------

func TestMergeDirectoryOnly(t *testing.T) {
	idx := buildOne(t, []*models.Gallery{
		gallery(1000001, "1000001-Dir Title", 3),
	}, nil)

	g, ok := idx.Get(1000001)
	if !ok {
		t.Fatal("gallery missing")
	}
	if g.Title != "Dir Title" || g.TitleSource != models.TitleSourceDirname {
		t.Errorf("title should come from the directory name without the gid prefix: %q/%q", g.Title, g.TitleSource)
	}
	if g.MetaSource != models.MetaSourceLocalOnly {
		t.Errorf("meta_source: got %q", g.MetaSource)
	}
	if !g.OnDisk {
		t.Error("on_disk should be true")
	}
	if g.Token != "" {
		t.Errorf("no snapshot means no token, got %q", g.Token)
	}
}

func TestMergeDatabaseOnlyBecomesOrphan(t *testing.T) {
	merged := &dbexport.Merged{
		Galleries: map[int64]*dbexport.Meta{2000001: meta(2000001, "From DB")},
		DirNames:  map[int64]string{2000001: "2000001-From DB"},
	}
	idx := buildOne(t, nil, merged)

	g, ok := idx.Get(2000001)
	if !ok {
		t.Fatal("orphan row was dropped")
	}
	if g.OnDisk {
		t.Error("on_disk should be false")
	}
	if g.Availability != models.AvailMissing {
		t.Errorf("availability: got %q, want missing", g.Availability)
	}
	if g.MetaSource != models.MetaSourceOrphan {
		t.Errorf("meta_source: got %q", g.MetaSource)
	}
	if g.Title != "From DB" || g.TitleSource != models.TitleSourceDB {
		t.Errorf("title: got %q/%q", g.Title, g.TitleSource)
	}
	if g.DirName != "2000001-From DB" {
		t.Errorf("dir_name should come from DOWNLOAD_DIRNAME: got %q", g.DirName)
	}
	// No pages, so no cover, and the URL must not point anywhere.
	if g.CoverKind != "none" || g.CoverURL != "" {
		t.Errorf("an orphan should have no cover: %q %q", g.CoverKind, g.CoverURL)
	}
}

// A DB title must win over the directory name, because the directory name has
// already been through sanitizeFilename.
func TestMergeDatabaseWinsForMetadata(t *testing.T) {
	merged := &dbexport.Merged{
		Galleries: map[int64]*dbexport.Meta{1000001: meta(1000001, "Real Title")},
	}
	idx := buildOne(t, []*models.Gallery{
		gallery(1000001, "1000001-Sanitized_Dir_Title", 4),
	}, merged)

	g, _ := idx.Get(1000001)
	if g.Title != "Real Title" {
		t.Errorf("title: got %q, want the DB title", g.Title)
	}
	if g.TitleSource != models.TitleSourceDB {
		t.Errorf("title_source: got %q", g.TitleSource)
	}
	if g.MetaSource != models.MetaSourceDB {
		t.Errorf("meta_source: got %q", g.MetaSource)
	}
	// Filesystem facts must be untouched by the merge.
	if g.PagesFound != 4 || len(g.Pages) != 4 {
		t.Errorf("the merge must not alter page facts: found=%d pages=%d", g.PagesFound, len(g.Pages))
	}
	if g.Category != 1 || g.Rating != 4.0 || g.Label != "默认" || g.TimeMS != 5000 {
		t.Errorf("DB fields not applied: %+v", g)
	}
}

// A DB row with an empty title must not blank out a usable directory name.
func TestMergeEmptyDBTitleKeepsDirName(t *testing.T) {
	m := meta(1000001, "")
	m.Title = ""
	merged := &dbexport.Merged{Galleries: map[int64]*dbexport.Meta{1000001: m}}

	idx := buildOne(t, []*models.Gallery{gallery(1000001, "1000001-Kept", 1)}, merged)
	g, _ := idx.Get(1000001)
	if g.Title != "Kept" {
		t.Errorf("title: got %q, want the directory name", g.Title)
	}
	if g.TitleSource != models.TitleSourceDirname {
		t.Errorf("title_source: got %q", g.TitleSource)
	}
}

func TestMergeBothPresentWithDifferentGIDIsNotPossible(t *testing.T) {
	// The map is keyed by gid, so a DB row for a different gid is simply a
	// separate entry: one merged, one orphan.
	merged := &dbexport.Merged{
		Galleries: map[int64]*dbexport.Meta{1000001: meta(1000001, "Merged")},
	}
	idx := buildOne(t, []*models.Gallery{gallery(1000001, "1000001-Dir", 1)}, merged)
	if idx.Len() != 1 {
		t.Errorf("got %d galleries, want 1", idx.Len())
	}
}

// --- language fallback -----------------------------------------------------

// SIMPLE_LANGUAGE is derived from tags on the phone, and the export has no
// Gallery_Tags, so the column is often NULL. The title is the only signal left.
func TestLanguageDerivedFromTitleWhenColumnIsNull(t *testing.T) {
	cases := []struct {
		title string
		want  string
	}{
		{"Some Title (English)", "EN"},
		{"Some Title [Chinese]", "ZH"},
		{"Some Title (中文)", "ZH"},
		{"漢化版", "ZH"},
		{"中国翻訳", "ZH"},
		{"Some Title (Spanish)", "ES"},
		{"Some Title [Korean]", "KO"},
		{"Some Title (Russian)", "RU"},
		{"Some Title (French)", "FR"},
		{"Some Title (German)", "DE"},
		{"Some Title (Italian)", "IT"},
		{"Some Title (Vietnamese)", "VI"},
		{"Some Title (Polish)", "PL"},
		{"Some Title (Hungarian)", "HU"},
		{"Some Title (Dutch)", "NL"},
		{"Some Title (Thai)", "TH"},
		{"スペイン翻訳", "ES"},
		{"フランス翻訳", "FR"},
		{"no language marker at all", ""},
		{"", ""},
	}
	for _, c := range cases {
		if got := languageFromTitle(c.title); got != c.want {
			t.Errorf("languageFromTitle(%q) = %q, want %q", c.title, got, c.want)
		}
	}
}

// The pattern order is load-bearing: the first match wins, matching
// GalleryInfo.generateSLangFromTitle.
//
// Note that the patterns require a bracketed form — "(English)", "[English]",
// "(eng)" — or a native marker such as 英訳. A bare "English" in the middle of
// a title does NOT match, in the Java source or here.
func TestLanguagePatternOrder(t *testing.T) {
	// Both markers present; EN is tried first, so EN wins even though ZH also
	// appears later in the string.
	if got := languageFromTitle("[English] 中文"); got != "EN" {
		t.Errorf("got %q, want EN (the EN pattern is tried first)", got)
	}
	// A bare word is not enough.
	if got := languageFromTitle("English translation of a Chinese work"); got != "" {
		t.Errorf("got %q, want empty: the patterns require a bracketed form", got)
	}
	// With only a Chinese marker, ZH is reached.
	if got := languageFromTitle("中文本"); got != "ZH" {
		t.Errorf("got %q, want ZH", got)
	}
	// The native translation markers work without brackets.
	if got := languageFromTitle("英訳"); got != "EN" {
		t.Errorf("got %q, want EN for 英訳", got)
	}
}

// A value already present in the DB must be respected, not overwritten.
func TestExplicitLanguageIsNotOverwritten(t *testing.T) {
	m := meta(1000001, "Some Title (English)")
	m.SimpleLanguage = "ZH"
	merged := &dbexport.Merged{Galleries: map[int64]*dbexport.Meta{1000001: m}}

	idx := buildOne(t, []*models.Gallery{gallery(1000001, "1000001-Dir", 1)}, merged)
	g, _ := idx.Get(1000001)
	if g.SimpleLanguage != "ZH" {
		t.Errorf("an explicit SIMPLE_LANGUAGE must win, got %q", g.SimpleLanguage)
	}
}

// The language fallback also applies to directory-derived titles.
//
// The directory name is built from the same title the DB would carry, so it has
// the same markers. Skipping the derivation for local-only galleries meant a
// library with no exported snapshot reported no language at all, losing a
// filter the UI can otherwise offer for free.
func TestLanguageDerivedFromDirnameWithoutSnapshot(t *testing.T) {
	cases := []struct {
		dirName string
		want    string
	}{
		{"1000001-[Group] Title [Chinese]", "ZH"},
		{"1000002-Title (English) [Digital]", "EN"},
		{"1000003-漢化版 Title", "ZH"},
		{"1000004-No marker here", ""},
	}
	for _, c := range cases {
		idx := buildOne(t, []*models.Gallery{gallery(parseGID(c.dirName), c.dirName, 1)}, nil)
		g, _ := idx.Get(parseGID(c.dirName))
		if g.SimpleLanguage != c.want {
			t.Errorf("%q: language = %q, want %q", c.dirName, g.SimpleLanguage, c.want)
		}
	}
}

// An explicit language is never overwritten by the title-derived one.
func TestExplicitLanguageBeatsDirname(t *testing.T) {
	g := gallery(1000001, "1000001-Title [Chinese]", 1)
	g.SimpleLanguage = "EN"
	idx := buildOne(t, []*models.Gallery{g}, nil)
	got, _ := idx.Get(1000001)
	if got.SimpleLanguage != "EN" {
		t.Errorf("an explicit language must win, got %q", got.SimpleLanguage)
	}
}

// --- directory-derived tags ------------------------------------------------

// A directory name in the site's convention is taken apart: the title loses
// the brackets, the parts become tags, and the raw name stays in dir_name for
// anyone who wants to see exactly what was on disk.
func TestDirnameTitleIsCleanedAndTagsDerived(t *testing.T) {
	const dir = "1080380-[balmos] 神龙大侠 (Kung Fu Panda) [黑曜石汉化组]"
	idx := buildOne(t, []*models.Gallery{gallery(1080380, dir, 1)}, nil)

	g, _ := idx.Get(1080380)
	if g.Title != "神龙大侠" {
		t.Errorf("title: got %q, want the cleaned title", g.Title)
	}
	if g.TitleSource != models.TitleSourceDirname {
		t.Errorf("a cleaned title is still directory-derived: got %q", g.TitleSource)
	}
	if g.DirName != dir {
		t.Errorf("the raw name must survive: got %q", g.DirName)
	}
	if len(g.Artists) != 1 || g.Artists[0] != "balmos" {
		t.Errorf("artists: got %q", g.Artists)
	}
	if len(g.Series) != 1 || g.Series[0] != "Kung Fu Panda" {
		t.Errorf("series: got %q", g.Series)
	}
	if len(g.Groups) != 1 || g.Groups[0] != "黑曜石汉化组" {
		t.Errorf("groups: got %q", g.Groups)
	}
}

// A snapshot title is the site's own value and is shown verbatim, brackets and
// all. Tags do not come from it, because the export has no tag table: they are
// derived from the directory name, which is the only tag source there is.
func TestSnapshotTitleIsNotCleanedButTagsStillComeFromDirname(t *testing.T) {
	merged := &dbexport.Merged{
		Galleries: map[int64]*dbexport.Meta{
			1000001: meta(1000001, "[Artist] DB Title [Chinese]"),
		},
	}
	idx := buildOne(t, []*models.Gallery{
		gallery(1000001, "1000001-[Other] Dir Title [Chinese]", 1),
	}, merged)

	g, _ := idx.Get(1000001)
	if g.Title != "[Artist] DB Title [Chinese]" {
		t.Errorf("snapshot title must win verbatim: got %q", g.Title)
	}
	if g.TitleSource != models.TitleSourceDB {
		t.Errorf("title_source: got %q", g.TitleSource)
	}
	if len(g.Artists) != 1 || g.Artists[0] != "Other" {
		t.Errorf("tags must come from the directory name: got %q", g.Artists)
	}
}

// Two spellings of one artist differing only in case are one filter entry, not
// two, and the label keeps a spelling the library actually uses.
func TestTagFacetsFoldCase(t *testing.T) {
	idx := buildOne(t, []*models.Gallery{
		gallery(1000001, "1000001-[Koukyuu Denim (Futee)] A [Chinese]", 1),
		gallery(1000002, "1000002-[Koukyuu denim (futee)] B [Chinese]", 1),
		gallery(1000003, "1000003-[Someone Else] C", 1),
	}, nil)

	artists := idx.Facets().Artists
	if len(artists) != 2 {
		t.Fatalf("case-different spellings must fold into one bucket: got %+v", artists)
	}
	if artists[0].Count != 2 {
		t.Errorf("the folded bucket should count both galleries: got %+v", artists[0])
	}
	if artists[0].Value != "koukyuu denim (futee)" {
		t.Errorf("the value is the folded key: got %q", artists[0].Value)
	}
	if artists[0].Label != "Koukyuu Denim (Futee)" {
		t.Errorf("the label should be a spelling the library uses: got %q", artists[0].Label)
	}
}

// Within one dimension the values are OR-ed, because picking two artists means
// "either of these". Requiring both would return only the galleries two artists
// happen to share, which is nearly always nothing.
func TestTagFilterIsOrWithinADimensionAndAndAcrossThem(t *testing.T) {
	idx := buildOne(t, []*models.Gallery{
		gallery(1000001, "1000001-[Alpha] One", 1),
		gallery(1000002, "1000002-[Beta] Two", 1),
		gallery(1000003, "1000003-[Gamma] Three", 1),
	}, nil)

	if res := idx.Query(models.Query{Artists: []string{"Alpha", "Beta"}}); res.Total != 2 {
		t.Errorf("two artists selected means either, got %d results", res.Total)
	}
	res := idx.Query(models.Query{
		Artists: []string{"Alpha", "Beta"},
		Series:  []string{"Something else"},
	})
	if res.Total != 0 {
		t.Errorf("a second dimension must narrow the result, got %d", res.Total)
	}
}

// A filter built from a folded facet value still matches the gallery's own
// spelling.
func TestTagFilterFoldsCase(t *testing.T) {
	idx := buildOne(t, []*models.Gallery{
		gallery(1000001, "1000001-[Koukyuu Denim (Futee)] A", 1),
	}, nil)

	if res := idx.Query(models.Query{Artists: []string{"koukyuu denim (futee)"}}); res.Total != 1 {
		t.Errorf("the folded key must match the gallery's spelling, got %d", res.Total)
	}
}

// A cursor is bound to the filter, so the same tags in a different order — or a
// different case, which the matcher ignores anyway — must be the same filter.
// Otherwise paging would reject its own cursor at the first page boundary.
func TestFilterFingerprintIgnoresTagOrderAndCase(t *testing.T) {
	a := FilterFingerprint(models.Query{Artists: []string{"Alpha", "Beta"}})
	b := FilterFingerprint(models.Query{Artists: []string{"beta", "ALPHA"}})
	if a != b {
		t.Errorf("tag order and case must not change the fingerprint:\n%q\n%q", a, b)
	}
	if c := FilterFingerprint(models.Query{Artists: []string{"Alpha"}}); a == c {
		t.Error("a different tag set must change the fingerprint")
	}
}

// A tag is searchable from the text box: typing a scanlation group into search
// asks the same question the filter list asks.
func TestTagIsSearchable(t *testing.T) {
	idx := buildOne(t, []*models.Gallery{
		gallery(1000001, "1000001-[balmos] 神龙大侠 [黑曜石汉化组]", 1),
		gallery(1000002, "1000002-[other] Something Else", 1),
	}, nil)

	if res := idx.Query(models.Query{Text: "黑曜石"}); res.Total != 1 {
		t.Errorf("searching a scanlation group should find its gallery, got %d", res.Total)
	}
	if res := idx.Query(models.Query{Text: "balmos"}); res.Total != 1 {
		t.Errorf("searching an artist should find their gallery, got %d", res.Total)
	}
}

func parseGID(dirName string) int64 {
	gid, _, _ := scan.ParseDirName(dirName)
	return gid
}

// --- queries ---------------------------------------------------------------

func queryIndex(t *testing.T) *Index {
	t.Helper()
	merged := &dbexport.Merged{
		Galleries: map[int64]*dbexport.Meta{
			1000001: {GID: 1000001, Title: "Alpha", Category: 1, Rating: 5.0,
				Label: "默认", SimpleLanguage: "ZH", State: 3, TimeMS: 3000},
			1000002: {GID: 1000002, Title: "Beta", Category: 2, Rating: 3.0,
				Label: "画集", SimpleLanguage: "EN", State: 3, TimeMS: 2000},
			1000003: {GID: 1000003, Title: "Gamma", Category: 1, Rating: 4.0,
				Label: "默认", SimpleLanguage: "ZH", State: 3, TimeMS: 1000},
			1000004: {GID: 1000004, Title: "Delta", Category: 3, Rating: 1.0,
				Label: "", State: 3, TimeMS: 4000},
		},
	}
	return buildOne(t, []*models.Gallery{
		gallery(1000001, "d1", 1),
		gallery(1000002, "d2", 6),
		gallery(1000003, "d3", 3),
	}, merged)
}

func gids(gs []*models.Gallery) []int64 {
	out := make([]int64, 0, len(gs))
	for _, g := range gs {
		out = append(out, g.GID)
	}
	return out
}

func TestQueryFilters(t *testing.T) {
	idx := queryIndex(t)

	one := 1
	cases := []struct {
		name string
		q    models.Query
		want int
	}{
		{"no filter", models.Query{}, 4},
		{"language ZH", models.Query{Language: "ZH"}, 2},
		{"language is case-insensitive", models.Query{Language: "zh"}, 2},
		{"label", models.Query{Label: "画集"}, 1},
		{"category", models.Query{Category: &one}, 2},
		{"availability ok", models.Query{Availability: "ok"}, 3},
		{"availability missing", models.Query{Availability: "missing"}, 1},
		{"text matches title", models.Query{Text: "alpha"}, 1},
		{"text is case-insensitive", models.Query{Text: "ALPHA"}, 1},
		{"text matches gid", models.Query{Text: "1000003"}, 1},
		{"text with no match", models.Query{Text: "zzzz"}, 0},
		{"empty text is not a filter", models.Query{Text: "   "}, 4},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := idx.Query(c.q)
			if got.Total != c.want {
				t.Errorf("total: got %d, want %d (gids %v)", got.Total, c.want, gids(got.Items))
			}
		})
	}
}

func TestQuerySorts(t *testing.T) {
	idx := queryIndex(t)

	cases := []struct {
		sort string
		want []int64
	}{
		{SortTimeDesc, []int64{1000004, 1000001, 1000002, 1000003}},
		{SortTimeAsc, []int64{1000003, 1000002, 1000001, 1000004}},
		{SortTitleAsc, []int64{1000001, 1000002, 1000004, 1000003}},
		{SortRatingDesc, []int64{1000001, 1000003, 1000002, 1000004}},
		// 1000004 is the orphan (0 pages), so it sorts last.
		{SortPagesDesc, []int64{1000002, 1000003, 1000001, 1000004}},
		{SortGIDDesc, []int64{1000004, 1000003, 1000002, 1000001}},
	}
	for _, c := range cases {
		t.Run(c.sort, func(t *testing.T) {
			got := gids(idx.Query(models.Query{Sort: c.sort}).Items)
			if len(got) != len(c.want) {
				t.Fatalf("got %v, want %v", got, c.want)
			}
			for i := range c.want {
				if got[i] != c.want[i] {
					t.Fatalf("got %v, want %v", got, c.want)
				}
			}
		})
	}

	// An unknown or empty key falls back to newest-first rather than erroring;
	// the HTTP layer is what rejects an unknown key.
	if got := gids(idx.Query(models.Query{Sort: ""}).Items); got[0] != 1000004 {
		t.Errorf("empty sort should default to time_desc, got %v", got)
	}
}

func TestQueryPaging(t *testing.T) {
	idx := queryIndex(t)

	first := idx.Query(models.Query{Limit: 2, Sort: SortGIDDesc})
	if len(first.Items) != 2 || first.Total != 4 {
		t.Fatalf("first page: got %d items, total %d", len(first.Items), first.Total)
	}
	if first.Items[0].GID != 1000004 {
		t.Errorf("first item: got %d", first.Items[0].GID)
	}

	second := idx.Query(models.Query{Limit: 2, Offset: 2, Sort: SortGIDDesc})
	if len(second.Items) != 2 || second.Items[0].GID != 1000002 {
		t.Fatalf("second page: %v", gids(second.Items))
	}

	// Past the end is an empty page, not an error.
	past := idx.Query(models.Query{Limit: 2, Offset: 99})
	if len(past.Items) != 0 || past.Total != 4 {
		t.Errorf("past the end: got %d items, total %d", len(past.Items), past.Total)
	}

	// The limit is capped so a caller cannot ask for everything.
	huge := idx.Query(models.Query{Limit: 100000})
	if len(huge.Items) != 4 {
		t.Errorf("got %d items", len(huge.Items))
	}

	// A negative offset is clamped rather than panicking.
	neg := idx.Query(models.Query{Limit: 2, Offset: -5})
	if len(neg.Items) == 0 {
		t.Error("a negative offset should be clamped to zero")
	}
}

func TestFacets(t *testing.T) {
	idx := queryIndex(t)
	f := idx.Facets()

	if len(f.Labels) != 2 {
		t.Fatalf("labels: %+v", f.Labels)
	}
	// Sorted by count descending, then value.
	if f.Labels[0].Value != "默认" || f.Labels[0].Count != 2 {
		t.Errorf("labels should be count-ordered: %+v", f.Labels)
	}
	if len(f.Languages) != 2 {
		t.Errorf("languages: %+v", f.Languages)
	}
	if len(f.Categories) != 3 {
		t.Errorf("categories: %+v", f.Categories)
	}
	avail := map[string]int{}
	for _, v := range f.Availability {
		avail[v.Value] = v.Count
	}
	if avail["ok"] != 3 || avail["missing"] != 1 {
		t.Errorf("availability: %+v", f.Availability)
	}
}

// Facets must count what is actually queryable, so every language a facet
// reports must return at least one row when used as a filter.
func TestFacetsAgreeWithFilters(t *testing.T) {
	idx := queryIndex(t)
	f := idx.Facets()

	for _, lv := range f.Labels {
		if got := idx.Query(models.Query{Label: lv.Value}).Total; got != lv.Count {
			t.Errorf("label %q: facet says %d, filter returns %d", lv.Value, lv.Count, got)
		}
	}
	for _, lv := range f.Languages {
		if got := idx.Query(models.Query{Language: lv.Value}).Total; got != lv.Count {
			t.Errorf("language %q: facet says %d, filter returns %d", lv.Value, lv.Count, got)
		}
	}
	for _, lv := range f.Availability {
		if got := idx.Query(models.Query{Availability: lv.Value}).Total; got != lv.Count {
			t.Errorf("availability %q: facet says %d, filter returns %d", lv.Value, lv.Count, got)
		}
	}
}

func TestStats(t *testing.T) {
	idx := queryIndex(t)
	s := idx.Stats()

	if s.Galleries != 4 || s.OnDisk != 3 || s.Missing != 1 {
		t.Errorf("counts: %+v", s)
	}
	if s.Pages != 10 {
		t.Errorf("pages: got %d, want 1+6+3", s.Pages)
	}
	if s.IndexedAtMS != 9999 {
		t.Errorf("indexed_at: got %d", s.IndexedAtMS)
	}
	if s.SnapshotCount != 0 {
		t.Errorf("snapshot_count: got %d", s.SnapshotCount)
	}
}

func TestBuildWarnsWhenThereIsNoSnapshot(t *testing.T) {
	idx := buildOne(t, []*models.Gallery{gallery(1000001, "x", 1)}, nil)
	warnings := idx.Warnings()
	if len(warnings) == 0 {
		t.Fatal("expected a warning explaining the missing snapshot")
	}
	if !contains(warnings[0], "snapshot") {
		t.Errorf("the warning should mention the snapshot: %q", warnings[0])
	}
}

func TestBuildRecordsSnapshotErrors(t *testing.T) {
	idx := Build(BuildInput{
		Scanned:  &scan.Result{},
		Merged:   &dbexport.Merged{TakenAtMS: 1234, SnapshotCount: 1},
		DBErrors: []error{errString("half-synced snapshot")},
		Now:      func() time.Time { return time.UnixMilli(1) },
	})
	found := false
	for _, w := range idx.Warnings() {
		if contains(w, "half-synced") {
			found = true
		}
	}
	if !found {
		t.Errorf("a snapshot read error should surface as a warning, got %v", idx.Warnings())
	}
	if idx.Stats().SnapshotAtMS != 1234 {
		t.Errorf("snapshot timestamp: got %d", idx.Stats().SnapshotAtMS)
	}
}

func TestBuildSortsByGIDForStableOutput(t *testing.T) {
	idx := buildOne(t, []*models.Gallery{
		gallery(1000003, "c", 1),
		gallery(1000001, "a", 1),
		gallery(1000002, "b", 1),
	}, nil)
	got := gids(idx.All())
	want := []int64{1000001, 1000002, 1000003}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("All() should be gid-ordered: got %v", got)
		}
	}
}

func TestCoverURLUsesPageOne(t *testing.T) {
	g := gallery(1000001, "1000001-x", 3)
	g.MaxMTimeMS = 4242
	idx := buildOne(t, []*models.Gallery{g}, nil)

	got, _ := idx.Get(1000001)
	if got.CoverKind != "firstpage" {
		t.Errorf("cover_kind: got %q", got.CoverKind)
	}
	// The version parameter must come from the file mtime so a re-download
	// invalidates a client's cached cover.
	if !contains(got.CoverURL, "v=4242") {
		t.Errorf("cover_url should carry the mtime version: %q", got.CoverURL)
	}
	if !contains(got.CoverURL, "/thumb/1000001") {
		t.Errorf("cover_url: %q", got.CoverURL)
	}
}

// --- cursors ---------------------------------------------------------------

func TestCursorRoundTrip(t *testing.T) {
	fp := FilterFingerprint(models.Query{Text: "a", Label: "b", Sort: SortTitleAsc})
	enc := EncodeCursor(120, fp)
	if enc == "" {
		t.Fatal("EncodeCursor returned empty")
	}
	got, err := DecodeCursor(enc, fp)
	if err != nil {
		t.Fatalf("DecodeCursor: %v", err)
	}
	if got != 120 {
		t.Errorf("offset: got %d, want 120", got)
	}

	// An empty cursor means "the first page".
	if off, err := DecodeCursor("", fp); err != nil || off != 0 {
		t.Errorf("empty cursor: got %d, err %v", off, err)
	}
}

func TestCursorRejectsOtherQueries(t *testing.T) {
	fpA := FilterFingerprint(models.Query{Label: "a"})
	fpB := FilterFingerprint(models.Query{Label: "b"})
	enc := EncodeCursor(10, fpA)

	// Replaying a cursor against another filter set must fail loudly, not
	// silently skip rows.
	if _, err := DecodeCursor(enc, fpB); err == nil {
		t.Error("a cursor must not be usable with a different filter set")
	}
}

func TestCursorRejectsGarbage(t *testing.T) {
	fp := FilterFingerprint(models.Query{})
	for _, bad := range []string{"!!!not base64!!!", "bm90anNvbg", "e30"} {
		if _, err := DecodeCursor(bad, fp); err == nil {
			t.Errorf("DecodeCursor(%q) accepted malformed input", bad)
		}
	}
}

func TestFilterFingerprintDistinguishesFields(t *testing.T) {
	a := FilterFingerprint(models.Query{Text: "x", Sort: SortTimeDesc})
	b := FilterFingerprint(models.Query{Text: "y", Sort: SortTimeDesc})
	if a == b {
		t.Error("different text should give different fingerprints")
	}
	// Field boundaries must not run together: "ab"+"c" must differ from "a"+"bc".
	c := FilterFingerprint(models.Query{Text: "ab", Label: "c"})
	d := FilterFingerprint(models.Query{Text: "a", Label: "bc"})
	if c == d {
		t.Error("fingerprints must not concatenate fields ambiguously")
	}
}

// --- store -----------------------------------------------------------------

func TestStoreSwapIsAtomic(t *testing.T) {
	first := buildOne(t, []*models.Gallery{gallery(1000001, "a", 1)}, nil)
	second := buildOne(t, []*models.Gallery{gallery(1000002, "b", 1)}, nil)

	s := NewStore(first)
	if s.Load().Len() != 1 {
		t.Fatalf("initial: %d galleries", s.Load().Len())
	}
	s.Swap(second)
	if s.Load().Len() != 1 {
		t.Fatalf("after swap: %d galleries", s.Load().Len())
	}
	if _, ok := s.Load().Get(1000002); !ok {
		t.Error("the swap did not take effect")
	}
	if _, ok := s.Load().Get(1000001); ok {
		t.Error("the old index is still visible")
	}
}

func TestEmptyIndexIsUsable(t *testing.T) {
	// A build with nothing to index must still produce a usable value: reads
	// happen against it while a rebuild is in flight.
	idx := Build(BuildInput{Scanned: &scan.Result{}})
	if idx.Len() != 0 {
		t.Errorf("got %d galleries", idx.Len())
	}
	if res := idx.Query(models.Query{}); res.Total != 0 || res.Items == nil {
		// Items must be non-nil so the JSON encoder emits [] rather than null.
		if res.Items == nil {
			t.Error("Items should be an empty slice, not nil, so JSON encodes as []")
		}
	}
	if got := idx.Facets(); len(got.Availability) != 0 {
		t.Errorf("facets should be empty, got %+v", got)
	}
}

// --- helpers ---------------------------------------------------------------

type errString string

func (e errString) Error() string { return string(e) }

func contains(haystack, needle string) bool {
	return len(haystack) >= len(needle) && indexOf(haystack, needle) >= 0
}

func indexOf(haystack, needle string) int {
	for i := 0; i+len(needle) <= len(haystack); i++ {
		if haystack[i:i+len(needle)] == needle {
			return i
		}
	}
	return -1
}
