// Package watch turns filesystem events into debounced index rebuilds.
//
// Syncthing is a noisy writer: a single gallery arriving over the network
// produces one event per file plus temporary artifacts, and a large sync can
// keep events flowing for minutes. Rebuilding on every event would saturate a
// core, so events are coalesced into a debounce window with a hard ceiling
// that guarantees progress even under continuous writes.
//
// Only two things trigger a rebuild here:
//
//   - a change anywhere under the gallery tree, or
//   - a new or changed *.db snapshot.
//
// The distinction matters because the caller may want to rebuild only if a
// snapshot actually landed.
package watch

import (
	"context"
	"errors"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/fsnotify/fsnotify"
)

// Options configures a Watcher.
type Options struct {
	// Roots are directory trees to watch recursively.
	Roots []string
	// DBDirs are snapshot directories. Watched non-recursively.
	DBDirs []string
	// Debounce is the coalescing window. Zero uses 2s.
	Debounce time.Duration
	// MaxDelay forces a rebuild if events keep arriving. Zero uses 30s.
	MaxDelay time.Duration
	// OnChange is called after a debounce window expires. It may be slow.
	//
	// dbChanged reports whether any event in the batch touched a .db file.
	OnChange func(ctx context.Context, dbChanged bool)
	// Logger receives diagnostics.
	Logger *slog.Logger
}

// Watcher watches the synced tree and invokes a callback on change.
type Watcher struct {
	opts    Options
	log     *slog.Logger
	fsw     *fsnotify.Watcher
	done    chan struct{}
	closeMu sync.Mutex
	closed  bool

	mu        sync.Mutex
	pending   bool
	dbPending bool
	firstAt   time.Time
	timer     *time.Timer
}

// New starts a watcher.
func New(opts Options) (*Watcher, error) {
	if opts.OnChange == nil {
		return nil, errors.New("watch: OnChange is required")
	}
	if opts.Debounce <= 0 {
		opts.Debounce = 2 * time.Second
	}
	if opts.MaxDelay <= 0 {
		opts.MaxDelay = 30 * time.Second
	}
	log := opts.Logger
	if log == nil {
		log = slog.Default()
	}

	fsw, err := fsnotify.NewWatcher()
	if err != nil {
		return nil, err
	}

	w := &Watcher{
		opts: opts,
		log:  log,
		fsw:  fsw,
		done: make(chan struct{}),
	}

	// Watch each root recursively. Directories are added as they appear so a
	// gallery synced later is still observed.
	for _, root := range opts.Roots {
		if err := w.addTree(root); err != nil {
			w.log.Warn("cannot watch root", "root", root, "error", err)
		}
	}
	// Snapshot directories are watched flat: the files are short-lived and
	// there is no nested structure worth descending into.
	for _, dir := range opts.DBDirs {
		if dir == "" {
			continue
		}
		if err := w.fsw.Add(dir); err != nil {
			w.log.Warn("cannot watch db dir", "dir", dir, "error", err)
		}
	}

	go w.loop()
	return w, nil
}

// addTree registers dir and every subdirectory beneath it.
func (w *Watcher) addTree(dir string) error {
	return filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			// A directory can vanish mid-walk (Syncthing was deleting it).
			// That is not a reason to abort the whole watch.
			return nil
		}
		if !d.IsDir() {
			return nil
		}
		if path != dir && isIgnoredDir(d.Name()) {
			return filepath.SkipDir
		}
		if err := w.fsw.Add(path); err != nil {
			w.log.Warn("cannot watch directory", "path", path, "error", err)
		}
		return nil
	})
}

// Close stops the watcher and waits for the loop to exit.
func (w *Watcher) Close() error {
	w.closeMu.Lock()
	if w.closed {
		w.closeMu.Unlock()
		return nil
	}
	w.closed = true
	close(w.done)
	w.closeMu.Unlock()

	w.mu.Lock()
	if w.timer != nil {
		w.timer.Stop()
	}
	w.mu.Unlock()

	return w.fsw.Close()
}

func (w *Watcher) loop() {
	for {
		select {
		case <-w.done:
			return
		case ev, ok := <-w.fsw.Events:
			if !ok {
				return
			}
			w.handleEvent(ev)
		case err, ok := <-w.fsw.Errors:
			if !ok {
				return
			}
			w.log.Warn("filesystem watch error", "error", err)
		}
	}
}

func (w *Watcher) handleEvent(ev fsnotify.Event) {
	name := filepath.Base(ev.Name)

	// Temp files from the sync process itself: ignoring these is what keeps
	// the event rate sane during a large transfer.
	if isIgnoredName(name) {
		return
	}

	if ev.Has(fsnotify.Create) {
		// A new directory needs a watch of its own, otherwise a gallery synced
		// after startup is never seen changing.
		if fi, err := os.Stat(ev.Name); err == nil && fi.IsDir() {
			if err := w.addTree(ev.Name); err != nil {
				w.log.Warn("cannot watch new directory", "path", ev.Name, "error", err)
			}
		}
	}

	dbChanged := strings.EqualFold(filepath.Ext(name), ".db")
	w.mark(dbChanged)
}

// mark records a pending change and (re)arms the debounce timer.
func (w *Watcher) mark(dbChanged bool) {
	w.mu.Lock()
	defer w.mu.Unlock()

	now := time.Now()
	if !w.pending {
		w.pending = true
		w.firstAt = now
	}
	if dbChanged {
		w.dbPending = true
	}

	// Under a continuous write stream the timer would otherwise never fire.
	// Once the ceiling is reached, stop deferring.
	elapsed := now.Sub(w.firstAt)
	if elapsed >= w.opts.MaxDelay {
		w.fireLocked()
		return
	}
	remaining := w.opts.Debounce
	if ceiling := w.opts.MaxDelay - elapsed; remaining > ceiling {
		remaining = ceiling
	}
	if w.timer != nil {
		w.timer.Stop()
	}
	w.timer = time.AfterFunc(remaining, w.fire)
}

func (w *Watcher) fire() {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.fireLocked()
}

// fireLocked runs the callback. Callers must hold w.mu, and the callback is
// invoked in a fresh goroutine so a slow rebuild never blocks event intake.
func (w *Watcher) fireLocked() {
	if !w.pending {
		return
	}
	dbChanged := w.dbPending
	w.pending = false
	w.dbPending = false
	if w.timer != nil {
		w.timer.Stop()
		w.timer = nil
	}

	// A zero-value Logger panics on use, and the recovery path below must not
	// itself be able to panic, so this is resolved once here rather than at
	// each call site.
	logger := w.log
	if logger == nil {
		logger = slog.Default()
	}

	go func() {
		defer func() {
			if rec := recover(); rec != nil {
				logger.Error("panic in watch callback", "panic", rec)
			}
		}()
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
		defer cancel()
		logger.Debug("rebuilding index after filesystem change", "db_changed", dbChanged)
		w.opts.OnChange(ctx, dbChanged)
	}()
}

// --- name filters ----------------------------------------------------------

func isIgnoredDir(name string) bool {
	switch name {
	case ".stversions", ".stfolder", ".git", "node_modules":
		return true
	}
	return false
}

// isIgnoredName filters Syncthing and editor noise. Kept in sync with the
// scanner's rules: both must agree, or the watcher rebuilds for files the
// scanner will not index.
func isIgnoredName(name string) bool {
	if name == ".stfolder" || name == ".stversions" || name == ".stignore" || name == ".DS_Store" {
		return true
	}
	if strings.HasPrefix(name, "~syncthing~") {
		return true
	}
	if strings.HasSuffix(name, ".tmp") {
		return true
	}
	if strings.HasSuffix(name, ".swp") || strings.HasPrefix(name, ".goutputstream") {
		return true
	}
	// Syncthing conflict copies are skipped by the scanner, so a change to
	// one should not trigger a rebuild either.
	if strings.Contains(name, ".sync-conflict-") {
		return true
	}
	return false
}
