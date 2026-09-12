package index

import (
	"testing"

	"github.com/warren/ehviewer-webd/internal/models"
	"github.com/warren/ehviewer-webd/internal/scan"
)

func buildG(t *testing.T, galleries ...*models.Gallery) *Index {
	t.Helper()
	return Build(BuildInput{
		Scanned: &scan.Result{Galleries: galleries},
		Merged:  nil,
	})
}

func TestDiffDetectsAddedRemovedAndChanged(t *testing.T) {
	before := buildG(t,
		gallery(1000001, "1000001-a", 1),
		gallery(1000002, "1000002-b", 2),
		gallery(1000003, "1000003-c", 3),
	)

	changed := gallery(1000002, "1000002-b", 5) // page count differs
	after := buildG(t,
		gallery(1000001, "1000001-a", 1),
		changed,
		gallery(1000004, "1000004-d", 1), // added; 1000003 removed
	)

	d := Diff(before, after)
	if len(d.Added) != 1 || d.Added[0] != 1000004 {
		t.Errorf("added: got %v, want [1000004]", d.Added)
	}
	if len(d.Removed) != 1 || d.Removed[0] != 1000003 {
		t.Errorf("removed: got %v, want [1000003]", d.Removed)
	}
	if len(d.Changed) != 1 || d.Changed[0] != 1000002 {
		t.Errorf("changed: got %v, want [1000002]", d.Changed)
	}
	if d.Truncated {
		t.Error("a small diff must not be truncated")
	}
	if d.Empty() {
		t.Error("a non-empty diff reported itself empty")
	}
	if d.Total() != 3 {
		t.Errorf("total: got %d, want 3", d.Total())
	}
}

func TestDiffOfIdenticalIndexesIsEmpty(t *testing.T) {
	build := func() *Index {
		return buildG(t,
			gallery(1000001, "1000001-a", 1),
			gallery(1000002, "1000002-b", 2),
		)
	}
	d := Diff(build(), build())
	if !d.Empty() {
		t.Errorf("identical indexes produced a diff: %+v", d)
	}
}

// A change the client cannot render must not produce an event.
//
// This is the case that makes the fingerprint worth having: a rebuild re-stats
// every page, so per-file mtimes and sizes are re-read constantly. Comparing
// whole structs would report every gallery as changed on every rescan and wake
// every connected client for nothing.
//
// Note what is deliberately NOT asserted here: a change to the gallery's own
// maximum mtime *is* a visible change, because cover_url carries it as a
// cache-busting version. That is correct — a re-downloaded cover must be
// refetched — so only page-level bookkeeping is expected to be invisible.
func TestDiffIgnoresChangesTheClientCannotSee(t *testing.T) {
	before := buildG(t, gallery(1000001, "1000001-a", 2))

	// Same rendered fields, different per-page bookkeeping. MaxMTimeMS is left
	// alone, so the cover version does not move.
	touched := gallery(1000001, "1000001-a", 2)
	for i := range touched.Pages {
		touched.Pages[i].MTimeMS += 12345
		touched.Pages[i].Size += 999
	}
	touched.MaxMTimeMS = 0

	after := buildG(t, touched)
	// Build may have derived the cover version from the pages; force the same
	// one the baseline has so only page bookkeeping differs.
	baseline, _ := before.Get(1000001)
	got, _ := after.Get(1000001)
	got.CoverURL = baseline.CoverURL
	got.MaxMTimeMS = baseline.MaxMTimeMS

	d := Diff(before, after)
	if !d.Empty() {
		t.Errorf("a page-bookkeeping-only change produced a diff: %+v", d)
	}
}

// A cover version change IS visible: the client must refetch the thumbnail.
func TestDiffDetectsCoverVersionChange(t *testing.T) {
	before := buildG(t, gallery(1000001, "1000001-a", 2))

	bumped := gallery(1000001, "1000001-a", 2)
	bumped.MaxMTimeMS += 1000
	after := buildG(t, bumped)

	d := Diff(before, after)
	if len(d.Changed) != 1 {
		t.Errorf("a cover version change should be reported, got %+v", d)
	}
}

// Every field the client renders must be able to move the fingerprint.
func TestDiffDetectsEachRenderedField(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*models.Gallery)
	}{
		{"title", func(g *models.Gallery) { g.Title = "other" }},
		{"title_jpn", func(g *models.Gallery) { g.TitleJpn = "other" }},
		{"title_source", func(g *models.Gallery) { g.TitleSource = models.TitleSourceDB }},
		{"token", func(g *models.Gallery) { g.Token = "other" }},
		{"dir_name", func(g *models.Gallery) { g.DirName = "other" }},
		{"category", func(g *models.Gallery) { g.Category = 9 }},
		{"posted", func(g *models.Gallery) { g.Posted = "2024" }},
		{"uploader", func(g *models.Gallery) { g.Uploader = "someone" }},
		{"rating", func(g *models.Gallery) { g.Rating = 4.5 }},
		{"language", func(g *models.Gallery) { g.SimpleLanguage = "ZH" }},
		{"label", func(g *models.Gallery) { g.Label = "x" }},
		{"state", func(g *models.Gallery) { g.State = 5 }},
		{"time", func(g *models.Gallery) { g.TimeMS = 1234 }},
		{"pages_expected", func(g *models.Gallery) { g.PagesExpected = 99 }},
		{"pages_found", func(g *models.Gallery) { g.PagesFound = 99 }},
		{"total_bytes", func(g *models.Gallery) { g.TotalBytes = 999 }},
		{"cover_url", func(g *models.Gallery) { g.CoverURL = "/thumb/1?v=9" }},
		{"availability", func(g *models.Gallery) { g.Availability = models.AvailDegraded }},
		{"meta_source", func(g *models.Gallery) { g.MetaSource = models.MetaSourceDB }},
		{"on_disk", func(g *models.Gallery) { g.OnDisk = false }},
		{"anomalies", func(g *models.Gallery) {
			g.Anomalies = []string{models.AnomalyPageGap}
		}},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			before := buildG(t, gallery(1000001, "1000001-a", 2))

			// Clone through the index so Build has applied its own defaults
			// (availability, cover, language), then mutate one field.
			src := gallery(1000001, "1000001-a", 2)
			afterIdx := buildG(t, src)
			target, _ := afterIdx.Get(1000001)
			c.mutate(target)

			d := Diff(before, afterIdx)
			if len(d.Changed) != 1 {
				t.Errorf("changing %s produced changed=%v, want [1000001]", c.name, d.Changed)
			}
		})
	}
}

func TestDiffHandlesNilSides(t *testing.T) {
	idx := buildG(t, gallery(1000001, "1000001-a", 1))

	// First build: everything is added.
	d := Diff(nil, idx)
	if len(d.Added) != 1 || d.Added[0] != 1000001 {
		t.Errorf("added from nil: got %v", d.Added)
	}

	// Everything removed.
	d = Diff(idx, nil)
	if len(d.Removed) != 1 || d.Removed[0] != 1000001 {
		t.Errorf("removed to nil: got %v", d.Removed)
	}

	// Both nil.
	if !Diff(nil, nil).Empty() {
		t.Error("two nil indexes should produce an empty diff")
	}
}

// A bulk change must be marked truncated rather than sending an unbounded list.
func TestDiffTruncatesLargeChanges(t *testing.T) {
	const n = maxDiffGIDs + 50

	var before, after []*models.Gallery
	for i := 0; i < n; i++ {
		gid := int64(1000000 + i)
		before = append(before, gallery(gid, "g", 1))
		// Every gallery gains a page, so all of them changed.
		after = append(after, gallery(gid, "g", 2))
	}

	d := Diff(buildG(t, before...), buildG(t, after...))
	if !d.Truncated {
		t.Error("a diff above the cap must set Truncated")
	}
	if len(d.Changed) != maxDiffGIDs {
		t.Errorf("changed: got %d, want the %d cap", len(d.Changed), maxDiffGIDs)
	}
}

// The merge walk depends on both indexes being gid-sorted. Assert it, because
// a silent ordering change would turn the diff into nonsense.
func TestDiffReliesOnGIDOrdering(t *testing.T) {
	idx := buildG(t,
		gallery(1000003, "c", 1),
		gallery(1000001, "a", 1),
		gallery(1000002, "b", 1),
	)
	all := idx.All()
	for i := 1; i < len(all); i++ {
		if all[i-1].GID >= all[i].GID {
			t.Fatalf("index is not gid-sorted at %d: %d then %d",
				i, all[i-1].GID, all[i].GID)
		}
	}
}
