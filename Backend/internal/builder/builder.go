// Package builder wires a configuration to a concrete index build: it finds
// the synced directories, reads the newest usable DB snapshot, merges the two
// and swaps the result into the store.
//
// It is separate from package main so that tests and the reindex endpoint can
// drive a rebuild without starting an HTTP server or a watcher.
package builder

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"sync/atomic"
	"time"

	"github.com/warren/ehviewer-webd/internal/config"
	"github.com/warren/ehviewer-webd/internal/dbexport"
	"github.com/warren/ehviewer-webd/internal/index"
	"github.com/warren/ehviewer-webd/internal/scan"
)

// Publisher receives change notifications after a rebuild.
//
// Kept as an interface so this package does not depend on the events package:
// the only thing a builder needs to know is that something out there wants to
// hear about changes. A nil Publisher disables notification.
type Publisher interface {
	Broadcast(Event)
	Subscribers() int
}

// Event is the notification a Publisher receives.
//
// It mirrors events.Event field-for-field but is declared here so the two
// packages stay decoupled. The conversion happens in main.
type Event struct {
	IndexAtMS    int64
	SnapshotAtMS int64
	Galleries    int
	Added        []int64
	Changed      []int64
	Removed      []int64
	Truncated    bool
	Reason       string
}

// Builder performs rebuilds.
type Builder struct {
	cfg   config.Config
	store *index.Store
	log   *slog.Logger

	// publisher receives change notifications. Never nil after New.
	publisher Publisher

	// publishedAtMS guards against sending a notification for an index that
	// was already superseded, and lets the first build be announced only once.
	lastPublished atomic.Int64

	rescanEvery time.Duration
	lastDBScan  atomic.Int64
	rebuilding  atomic.Bool
}

// New creates a Builder.
//
// A nil store becomes an empty store. Every read path tolerates an empty index
// (a build that fails leaves it in place), so this keeps a builder usable as a
// pure "build me an index" helper in tests and in the scan subcommand.
func New(cfg config.Config, store *index.Store, log *slog.Logger) *Builder {
	return NewWithPublisher(cfg, store, log, nil)
}

// NewWithPublisher creates a Builder that notifies publisher of changes.
func NewWithPublisher(
	cfg config.Config,
	store *index.Store,
	log *slog.Logger,
	publisher Publisher,
) *Builder {
	if log == nil {
		log = slog.Default()
	}
	if store == nil {
		store = index.NewStore(index.Build(index.BuildInput{
			// An empty result: zero galleries, no warnings.
			Scanned: &scan.Result{},
		}))
	}
	return &Builder{
		cfg:         cfg,
		store:       store,
		log:         log,
		publisher:   publisher,
		rescanEvery: cfg.Sync.RescanInterval.Std(),
	}
}

// Store returns the store whose index is published.
func (b *Builder) Store() *index.Store { return b.store }

// Rebuild scans everything and swaps in a new index, using ReasonManual as the
// stated cause. Prefer RebuildFor when the cause is known.
//
// A rebuild is never allowed to leave the store empty: if the scan fails
// outright, the previous index stays live. That matters because Syncthing can
// transiently make a directory unreadable, and blanking the library at that
// moment would look like data loss to the client.
func (b *Builder) Rebuild(ctx context.Context) (*index.Index, error) {
	return b.RebuildFor(ctx, ReasonManual)
}

// RebuildFor rebuilds and reports why.
//
// The reason travels with the change notification, so a client can log or
// display something more useful than "the list changed".
func (b *Builder) RebuildFor(ctx context.Context, reason string) (*index.Index, error) {
	if !b.rebuilding.CompareAndSwap(false, true) {
		b.log.Info("a rebuild is already running; serving the current index")
		return b.store.Load(), nil
	}
	defer b.rebuilding.Store(false)

	started := time.Now()

	result := &scan.Result{}
	var scanErrs []string

	downloadDirs := b.resolveDownloadDirs()
	if len(downloadDirs) == 0 {
		return nil, fmt.Errorf(
			"builder: no gallery directory found. Checked sync.download_dirs %v under roots %v",
			b.cfg.Sync.DownloadDirs, b.cfg.Sync.Roots)
	}

	for _, dir := range downloadDirs {
		res, err := scan.Discover(dir, scan.LoadConfig{
			Options: scan.Options{
				Workers:      b.cfg.Sync.Workers,
				SkipSymlinks: b.cfg.Sync.SkipSymlinks,
				MaxPages:     b.cfg.Sync.MaxPages,
			},
		})
		if err != nil {
			scanErrs = append(scanErrs, fmt.Sprintf("%s: %v", dir, err))
			continue
		}
		b.log.Debug("scanned download directory",
			"dir", dir, "galleries", len(res.Galleries), "skipped", len(res.Skipped))
		result.Galleries = append(result.Galleries, res.Galleries...)
		result.Skipped = append(result.Skipped, res.Skipped...)
		result.DirCount += res.DirCount
	}

	if len(result.Galleries) == 0 && len(scanErrs) > 0 {
		return nil, fmt.Errorf("builder: every download directory failed: %v", scanErrs)
	}

	if max := b.cfg.Sync.MaxGalleries; max > 0 && len(result.Galleries) > max {
		return nil, fmt.Errorf(
			"builder: found %d galleries, above sync.max_galleries=%d; refusing to build. "+
				"This usually means sync.roots points at the wrong directory",
			len(result.Galleries), max)
	}

	merged, dbErrs := b.loadSnapshots()

	// Capture the previous index before swapping so the notification can carry
	// a real delta rather than "something changed".
	previous := b.store.Load()

	idx := index.Build(index.BuildInput{
		Scanned:  result,
		Merged:   merged,
		DBErrors: dbErrs,
		Now:      time.Now,
	})

	b.store.Swap(idx)

	stats := idx.Stats()
	b.log.Info("index rebuilt",
		"galleries", stats.Galleries,
		"on_disk", stats.OnDisk,
		"missing", stats.Missing,
		"degraded", stats.Degraded,
		"pages", stats.Pages,
		"skipped_dirs", stats.SkippedDirs,
		"snapshot_at_ms", stats.SnapshotAtMS,
		"duration_ms", time.Since(started).Milliseconds(),
	)
	for _, w := range idx.Warnings() {
		b.log.Warn("index warning", "warning", w)
	}

	b.publish(previous, idx, reason)
	return idx, nil
}

// publish notifies subscribers of what changed.
//
// Failures here must never fail a rebuild: the index is already swapped and
// serving, so a notification problem is cosmetic.
func (b *Builder) publish(previous, current *index.Index, reason string) {
	if b.publisher == nil || b.publisher.Subscribers() == 0 {
		return
	}
	// Skip a duplicate notification for an index that was already announced.
	// Two rebuilds can complete close together (a filesystem event and a
	// periodic rescan), and publishing twice for one index would make the
	// client refetch for nothing.
	stats := current.Stats()
	if !b.lastPublished.CompareAndSwap(0, stats.IndexedAtMS) {
		if stats.IndexedAtMS <= b.lastPublished.Load() {
			return
		}
		b.lastPublished.Store(stats.IndexedAtMS)
	}

	d := index.Diff(previous, current)
	if d.Empty() {
		// Nothing a client renders has changed, so waking every connected
		// client to refetch would be pure waste. A rebuild triggered by a page
		// being re-statted is exactly this case.
		return
	}
	b.publisher.Broadcast(Event{
		IndexAtMS:    stats.IndexedAtMS,
		SnapshotAtMS: stats.SnapshotAtMS,
		Galleries:    stats.Galleries,
		Added:        d.Added,
		Changed:      d.Changed,
		Removed:      d.Removed,
		Truncated:    d.Truncated,
		Reason:       reason,
	})
}

// Rebuild reasons, used for logging and for the event payload.
const (
	// ReasonStartup is the first build at startup.
	ReasonStartup = "startup"
	// ReasonWatch is a rebuild triggered by a filesystem change.
	ReasonWatch = "filesystem_change"
	// ReasonPeriodic is the fallback rescan.
	ReasonPeriodic = "periodic_rescan"
	// ReasonManual is a rebuild requested through the admin endpoint.
	ReasonManual = "manual"
)

// resolveDownloadDirs returns every existing candidate gallery directory
// across all roots.
func (b *Builder) resolveDownloadDirs() []string {
	var out []string
	seen := map[string]bool{}
	for _, root := range b.cfg.Sync.Roots {
		for _, dir := range b.cfg.ResolveDownloadDirs(root) {
			if seen[dir] {
				continue
			}
			seen[dir] = true
			out = append(out, dir)
		}
	}
	if len(out) == 0 && len(b.cfg.Sync.Roots) == 0 {
		// No roots configured at all: nothing to do.
		return nil
	}
	return out
}

// loadSnapshots finds and reads the exported DB snapshots.
//
// Any failure here is non-fatal by design: the library is still browsable
// without metadata, and a half-synced snapshot is an expected condition rather
// than an error worth refusing to start over.
func (b *Builder) loadSnapshots() (*dbexport.Merged, []error) {
	policy, _ := dbexport.ParseMergePolicy(b.cfg.Sync.DBPolicy)

	var candidates []dbexport.Candidate
	for _, root := range b.cfg.Sync.Roots {
		dir := b.cfg.ResolveDBDir(root)
		if dir == "" {
			continue
		}
		found, err := dbexport.ListCandidates(dir)
		if err != nil {
			b.log.Warn("cannot list snapshot directory", "dir", dir, "error", err)
			continue
		}
		candidates = append(candidates, found...)
	}
	if len(candidates) == 0 {
		return nil, nil
	}

	// Newest first, so logging the head names the snapshot in use.
	b.log.Info("reading exported DB snapshots",
		"count", len(candidates), "newest", filepath.Base(candidates[0].Path), "policy", policy)

	merged, errs := dbexport.LoadAll(candidates, policy)
	b.lastDBScan.Store(time.Now().UnixMilli())
	return merged, errs
}

// LastDBSnapshotPath reports the newest snapshot file seen, for logging.
func (b *Builder) LastDBSnapshotPath() string {
	for _, root := range b.cfg.Sync.Roots {
		if dir := b.cfg.ResolveDBDir(root); dir != "" {
			cands, err := dbexport.ListCandidates(dir)
			if err == nil && len(cands) > 0 {
				return cands[0].Path
			}
		}
	}
	return ""
}

// RescanInterval returns the configured fallback rescan period.
func (b *Builder) RescanInterval() time.Duration { return b.rescanEvery }

// WatchRoots returns the directories the watcher should observe.
func (b *Builder) WatchRoots() []string {
	return b.resolveDownloadDirs()
}

// WatchDBDirs returns the snapshot directories the watcher should observe.
func (b *Builder) WatchDBDirs() []string {
	var out []string
	for _, root := range b.cfg.Sync.Roots {
		if dir := b.cfg.ResolveDBDir(root); dir != "" {
			out = append(out, dir)
		}
	}
	return out
}

// EnsureDataDir creates the service data directory.
func EnsureDataDir(cfg config.Config) error {
	if cfg.DataDir == "" {
		return fmt.Errorf("builder: data_dir is empty")
	}
	if err := os.MkdirAll(cfg.DataDir, 0o755); err != nil {
		return fmt.Errorf("builder: create data_dir: %w", err)
	}
	return nil
}
