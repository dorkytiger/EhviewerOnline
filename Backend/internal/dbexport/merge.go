package dbexport

import "sort"

// Snapshot selection and merging.
//
// The phone can hold several exported snapshots at once, all synced into
// <root>/data/. Two policies are supported:
//
//	latest — use only the newest file. Predictable, and what the design doc
//	         recommends by default.
//	merge  — fold every snapshot from oldest to newest. This recovers
//	         galleries whose newest export dropped them, but it can also
//	         resurrect a row that a later export deliberately removed.
//
// Merge order matters: newer snapshots overwrite older ones for the same gid,
// never the other way around.

// MergePolicy selects how multiple snapshots are combined.
type MergePolicy string

const (
	// PolicyLatest uses only the newest snapshot.
	PolicyLatest MergePolicy = "latest"
	// PolicyMerge folds all snapshots, newest winning per gid.
	PolicyMerge MergePolicy = "merge"
)

// ParseMergePolicy validates a configured policy string.
func ParseMergePolicy(s string) (MergePolicy, bool) {
	switch MergePolicy(s) {
	case PolicyLatest:
		return PolicyLatest, true
	case PolicyMerge:
		return PolicyMerge, true
	default:
		return "", false
	}
}

// Merged is the effective metadata view over one or more snapshots.
type Merged struct {
	// Galleries is keyed by gid, newest snapshot wins.
	Galleries map[int64]*Meta
	// DirNames is keyed by gid, newest snapshot wins.
	DirNames map[int64]string
	// Labels is the union of all snapshots' labels, de-duplicated by name and
	// sorted.
	Labels []Label
	// TakenAtMS is the newest contributing snapshot's timestamp.
	TakenAtMS int64
	// SourcePath is the newest contributing snapshot.
	SourcePath string
	// SnapshotCount is how many snapshots contributed.
	SnapshotCount int
	// OriginPath records, per gid, which snapshot supplied the winning row.
	OriginPath map[int64]string
	// Warnings is the concatenation of every snapshot's warnings, prefixed by
	// file name.
	Warnings []string
}

// NewMerged returns an empty merged view.
func NewMerged() *Merged {
	return &Merged{
		Galleries:  map[int64]*Meta{},
		DirNames:   map[int64]string{},
		OriginPath: map[int64]string{},
	}
}

// Merge folds snaps into a single view.
//
// snaps must be ordered oldest-first for merge semantics to be correct. For
// PolicyLatest only the last element matters, but the whole slice is still
// walked so that labels and warnings from earlier files remain visible.
func Merge(snaps []*Snapshot, policy MergePolicy) *Merged {
	out := NewMerged()
	if len(snaps) == 0 {
		return out
	}

	labels := map[string]Label{}
	for _, snap := range snaps {
		if snap == nil {
			continue
		}
		out.SnapshotCount++
		if snap.TakenAtMS >= out.TakenAtMS {
			out.TakenAtMS = snap.TakenAtMS
			out.SourcePath = snap.Path
		}
		for _, w := range snap.Warnings {
			out.Warnings = append(out.Warnings, snap.Path+": "+w)
		}
		for _, l := range snap.Labels {
			key := l.Label
			prev, ok := labels[key]
			// Keep the earliest recorded time for stability across merges.
			if !ok || (l.Time != 0 && (prev.Time == 0 || l.Time < prev.Time)) {
				labels[key] = l
			}
		}

		if policy == PolicyLatest && snap != snaps[len(snaps)-1] {
			continue
		}
		for gid, m := range snap.Galleries {
			out.Galleries[gid] = m
			out.OriginPath[gid] = snap.Path
		}
		for gid, name := range snap.DirNames {
			out.DirNames[gid] = name
		}
	}

	for _, l := range labels {
		out.Labels = append(out.Labels, l)
	}
	// Deterministic order: by label text.
	sort.Slice(out.Labels, func(i, j int) bool {
		if out.Labels[i].Label != out.Labels[j].Label {
			return out.Labels[i].Label < out.Labels[j].Label
		}
		return out.Labels[i].ID < out.Labels[j].ID
	})
	return out
}

// LoadAll opens every candidate, oldest first, skipping any that fail. It
// returns the merged view plus the number of files that could not be read.
//
// A skipped file is normal: Syncthing may be mid-transfer. Callers should log
// the count and continue with what did load.
func LoadAll(candidates []Candidate, policy MergePolicy) (*Merged, []error) {
	// ListCandidates returns newest-first; merge wants oldest-first.
	ordered := make([]Candidate, len(candidates))
	for i, c := range candidates {
		ordered[len(candidates)-1-i] = c
	}

	var (
		snaps []*Snapshot
		errs  []error
	)
	for _, c := range ordered {
		snap, err := Open(c.Path)
		if err != nil {
			errs = append(errs, err)
			continue
		}
		snaps = append(snaps, snap)
	}
	return Merge(snaps, policy), errs
}
