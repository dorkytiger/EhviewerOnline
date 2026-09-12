package index

import (
	"strconv"
	"strings"

	"github.com/warren/ehviewer-webd/internal/models"
)

// Diff describes what changed between two builds.
type ChangeSet struct {
	// Added are gids present in the new index but not the old one.
	Added []int64
	// Removed are gids present in the old index but not the new one.
	Removed []int64
	// Changed are gids present in both whose rendered representation differs.
	Changed []int64
	// Truncated is set when a list was capped, so a caller can tell a consumer
	// to refetch wholesale instead of applying a partial delta.
	Truncated bool
}

// Empty reports whether nothing changed.
func (d ChangeSet) Empty() bool {
	return len(d.Added) == 0 && len(d.Removed) == 0 && len(d.Changed) == 0
}

// Total returns the number of affected galleries, before any cap.
func (d ChangeSet) Total() int {
	return len(d.Added) + len(d.Removed) + len(d.Changed)
}

// maxDiffGIDs caps each list. A first build, or a bulk sync that lands a whole
// season at once, can touch every gallery; sending a hundred thousand ids on
// every event would cost more than the event is worth. Past the cap the caller
// sets Truncated and the consumer refetches.
const maxDiffGIDs = 512

// Diff compares two indexes.
//
// Both indexes hold galleries sorted by gid, so this is a linear merge rather
// than two map constructions, and it needs no allocation beyond the result
// slices.
//
// A gallery counts as changed when any field the client renders differs. The
// comparison is on [galleryFingerprint] rather than on the struct, because
// fields the client never sees (page mtimes, file sizes) would otherwise
// produce events for changes that alter nothing on screen — and a rebuild
// caused by a single new page in one gallery would look like a change to every
// gallery whose pages were re-statted.
func Diff(oldIdx, newIdx *Index) ChangeSet {
	var d ChangeSet
	if oldIdx == nil && newIdx == nil {
		return d
	}
	if oldIdx == nil {
		for _, g := range newIdx.galleries {
			if len(d.Added) >= maxDiffGIDs {
				d.Truncated = true
				break
			}
			d.Added = append(d.Added, g.GID)
		}
		return d
	}
	if newIdx == nil {
		for _, g := range oldIdx.galleries {
			if len(d.Removed) >= maxDiffGIDs {
				d.Truncated = true
				break
			}
			d.Removed = append(d.Removed, g.GID)
		}
		return d
	}

	oldList, newList := oldIdx.galleries, newIdx.galleries
	i, j := 0, 0
	for i < len(oldList) && j < len(newList) {
		a, b := oldList[i], newList[j]
		switch {
		case a.GID == b.GID:
			if galleryFingerprint(a) != galleryFingerprint(b) {
				if len(d.Changed) < maxDiffGIDs {
					d.Changed = append(d.Changed, b.GID)
				} else {
					d.Truncated = true
				}
			}
			i++
			j++
		case a.GID < b.GID:
			if len(d.Removed) < maxDiffGIDs {
				d.Removed = append(d.Removed, a.GID)
			} else {
				d.Truncated = true
			}
			i++
		default:
			if len(d.Added) < maxDiffGIDs {
				d.Added = append(d.Added, b.GID)
			} else {
				d.Truncated = true
			}
			j++
		}
	}
	for ; i < len(oldList); i++ {
		if len(d.Removed) < maxDiffGIDs {
			d.Removed = append(d.Removed, oldList[i].GID)
		} else {
			d.Truncated = true
		}
	}
	for ; j < len(newList); j++ {
		if len(d.Added) < maxDiffGIDs {
			d.Added = append(d.Added, newList[j].GID)
		} else {
			d.Truncated = true
		}
	}
	return d
}

// galleryFingerprint builds a string of everything the client renders.
//
// Anything omitted from this string can change without the client being told,
// so the rule is: include a field if it appears in the list or detail DTO.
func galleryFingerprint(g *models.Gallery) string {
	var b strings.Builder
	b.Grow(192)

	writeInt := func(v int64) {
		b.WriteString(strconv.FormatInt(v, 10))
		b.WriteByte(0x1f)
	}
	writeStr := func(s string) {
		b.WriteString(s)
		// A unit separator, so "ab"+"c" cannot collide with "a"+"bc".
		b.WriteByte(0x1f)
	}

	writeInt(g.GID)
	writeStr(g.Title)
	writeStr(g.TitleJpn)
	writeStr(g.TitleSource)
	writeStr(g.Token)
	writeStr(g.DirName)
	writeInt(int64(g.Category))
	writeStr(g.Posted)
	writeStr(g.Uploader)
	// Rating is compared at display precision: a difference below what the UI
	// shows is not a visible change.
	writeInt(int64(g.Rating * 10))
	writeStr(g.SimpleLanguage)
	writeStr(g.Label)
	writeInt(int64(g.State))
	writeInt(g.TimeMS)
	writeInt(int64(g.PagesExpected))
	writeInt(int64(g.PagesFound))
	writeInt(g.TotalBytes)
	writeStr(g.CoverURL)
	writeStr(string(g.Availability))
	writeStr(g.MetaSource)
	if g.OnDisk {
		writeInt(1)
	} else {
		writeInt(0)
	}
	// Anomalies are ordered, so a stable join is enough.
	for _, a := range g.Anomalies {
		writeStr(a)
	}
	return b.String()
}
