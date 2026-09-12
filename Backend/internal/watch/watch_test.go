package watch

import (
	"context"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

func TestIgnoredNames(t *testing.T) {
	// Names the scanner also skips. The two lists must agree: if the watcher
	// rebuilds for a file the scanner ignores, a large sync produces pointless
	// work.
	ignored := []string{
		"~syncthing~00000001.jpg.tmp",
		"00000001.jpg.tmp",
		".stfolder",
		".stversions",
		".stignore",
		".DS_Store",
		"00000001.sync-conflict-20240101-120000-ABCDEFG.jpg",
		".goutputstream-ABCDEF",
		"index.html.swp",
	}
	for _, name := range ignored {
		if !isIgnoredName(name) {
			t.Errorf("%q should be ignored", name)
		}
	}

	// Real content and real snapshot files must NOT be ignored.
	kept := []string{
		"00000001.jpg",
		"00000001.JPG",
		".ehviewer",
		"20240101120000.db",
		"1234567-Some Gallery",
	}
	for _, name := range kept {
		if isIgnoredName(name) {
			t.Errorf("%q must not be ignored", name)
		}
	}
}

func TestIgnoredDirs(t *testing.T) {
	for _, d := range []string{".stversions", ".stfolder", ".git", "node_modules"} {
		if !isIgnoredDir(d) {
			t.Errorf("%q should not be descended into", d)
		}
	}
	for _, d := range []string{"download", "1234567-Gallery", "data"} {
		if isIgnoredDir(d) {
			t.Errorf("%q should be descended into", d)
		}
	}
}

// Bursts of events must collapse into a single callback.
//
// This is the property that keeps a large Syncthing transfer from saturating a
// core: one gallery arriving over the network emits one event per file.
func TestDebounceCoalescesABurst(t *testing.T) {
	root := t.TempDir()
	dbDir := t.TempDir()
	gallery := filepath.Join(root, "1234567-Gallery")
	if err := os.MkdirAll(gallery, 0o755); err != nil {
		t.Fatal(err)
	}

	var calls atomic.Int64
	var dbFlags atomic.Int64

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	w, err := New(Options{
		Roots:    []string{root},
		DBDirs:   []string{dbDir},
		Debounce: 150 * time.Millisecond,
		MaxDelay: 5 * time.Second,
		OnChange: func(_ context.Context, dbChanged bool) {
			calls.Add(1)
			if dbChanged {
				dbFlags.Add(1)
			}
		},
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	defer w.Close()

	// Ten rapid writes into one gallery.
	for i := 0; i < 10; i++ {
		name := filepath.Join(gallery, pad8(i)+".jpg")
		if err := os.WriteFile(name, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	deadline := time.Now().Add(3 * time.Second)
	for calls.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}

	if got := calls.Load(); got != 1 {
		t.Errorf("got %d callbacks for one burst, want exactly 1", got)
	}
	if got := dbFlags.Load(); got != 0 {
		t.Errorf("db_changed should be false for gallery files, got %d true callbacks", got)
	}
	_ = ctx
}

// A snapshot landing must be reported as such: a .db change is the signal that
// metadata, not just content, moved.
func TestSnapshotChangeIsFlagged(t *testing.T) {
	root := t.TempDir()
	dbDir := t.TempDir()

	var lastDB atomic.Bool
	var calls atomic.Int64

	w, err := New(Options{
		Roots:    []string{root},
		DBDirs:   []string{dbDir},
		Debounce: 80 * time.Millisecond,
		MaxDelay: 2 * time.Second,
		OnChange: func(_ context.Context, dbChanged bool) {
			calls.Add(1)
			lastDB.Store(dbChanged)
		},
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	defer w.Close()

	if err := os.WriteFile(filepath.Join(dbDir, "20240101120000.db"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	deadline := time.Now().Add(3 * time.Second)
	for calls.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if calls.Load() == 0 {
		t.Fatal("no callback for a snapshot change")
	}
	if !lastDB.Load() {
		t.Error("a .db change must be reported as db_changed")
	}
}

// Ignored files must not trigger a rebuild at all, even though fsnotify
// delivers events for them.
func TestIgnoredFilesDoNotTriggerRebuild(t *testing.T) {
	root := t.TempDir()
	var calls atomic.Int64

	w, err := New(Options{
		Roots:    []string{root},
		Debounce: 80 * time.Millisecond,
		MaxDelay: 2 * time.Second,
		OnChange: func(context.Context, bool) { calls.Add(1) },
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	defer w.Close()

	// Syncthing scratch files, which appear constantly during a transfer.
	for _, name := range []string{
		"~syncthing~00000001.jpg.tmp",
		"00000001.jpg.tmp",
		".stignore",
	} {
		if err := os.WriteFile(filepath.Join(root, name), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	time.Sleep(600 * time.Millisecond)
	if got := calls.Load(); got != 0 {
		t.Errorf("got %d callbacks for ignored files, want 0", got)
	}
}

// maxDelay must bound the coalescing window. Without it, a continuous write
// stream (a multi-minute sync) would defer the rebuild indefinitely and the
// library would appear frozen for the whole transfer.
func TestMaxDelayForcesProgress(t *testing.T) {
	w := &Watcher{
		opts: Options{
			Debounce: time.Hour, // never fires on its own
			MaxDelay: 50 * time.Millisecond,
			OnChange: func(context.Context, bool) {},
		},
		done: make(chan struct{}),
	}

	var fired atomic.Int64
	w.opts.OnChange = func(context.Context, bool) { fired.Add(1) }

	// Simulate a continuous stream: mark repeatedly over a window longer than
	// MaxDelay, with a debounce that would otherwise never elapse.
	start := time.Now()
	for time.Since(start) < 300*time.Millisecond {
		w.mark(false)
		time.Sleep(5 * time.Millisecond)
	}

	// At least one callback must have fired despite the huge debounce.
	deadline := time.Now().Add(2 * time.Second)
	for fired.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if fired.Load() == 0 {
		t.Error("MaxDelay did not force a rebuild during a continuous write stream")
	}

	w.mu.Lock()
	if w.timer != nil {
		w.timer.Stop()
	}
	w.mu.Unlock()
}

func TestNewRequiresCallback(t *testing.T) {
	if _, err := New(Options{Roots: []string{t.TempDir()}}); err == nil {
		t.Error("expected an error when OnChange is nil")
	}
}

func TestNewToleratesAMissingRoot(t *testing.T) {
	// A root can legitimately be absent at startup (the sync has not created
	// it yet). That must not be fatal.
	w, err := New(Options{
		Roots:    []string{filepath.Join(t.TempDir(), "not-created-yet")},
		OnChange: func(context.Context, bool) {},
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if err := w.Close(); err != nil {
		t.Errorf("Close: %v", err)
	}
}

func TestCloseIsIdempotent(t *testing.T) {
	w, err := New(Options{
		Roots:    []string{t.TempDir()},
		OnChange: func(context.Context, bool) {},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatalf("first Close: %v", err)
	}
	// A second Close must be a no-op rather than panicking on a closed channel.
	if err := w.Close(); err != nil {
		t.Errorf("second Close: %v", err)
	}
}

func pad8(n int) string {
	s := itoa(n)
	for len(s) < 8 {
		s = "0" + s
	}
	return s
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
