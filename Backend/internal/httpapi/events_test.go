package httpapi

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/warren/ehviewer-webd/internal/auth"
	"github.com/warren/ehviewer-webd/internal/events"
	"github.com/warren/ehviewer-webd/internal/index"
	"github.com/warren/ehviewer-webd/internal/models"
	"github.com/warren/ehviewer-webd/internal/scan"
)

// sseFrame is one parsed event from the stream.
type sseFrame struct {
	Name  string
	Data  string
	IsRaw bool // a comment line (keepalive)
}

// openStream starts a request against the handler and returns a reader that
// yields parsed frames.
//
// The handler blocks for the life of the stream, so it runs in its own
// goroutine; the caller cancels the returned function to end it. This mirrors
// how a real client behaves and, importantly, exercises the handler's
// ctx.Done path rather than a fake ResponseWriter that returns immediately.
func openStream(t *testing.T, h http.Handler, path string, timeout time.Duration) (<-chan sseFrame, func()) {
	t.Helper()

	ctx, cancel := context.WithCancel(context.Background())
	req := httptest.NewRequest(http.MethodGet, path, nil).WithContext(ctx)
	rec := httptest.NewRecorder()

	done := make(chan struct{})
	go func() {
		defer close(done)
		h.ServeHTTP(rec, req)
	}()

	frames := make(chan sseFrame, 32)
	go func() {
		defer close(frames)
		// httptest.ResponseRecorder writes into a bytes.Buffer, which is not
		// safe to read while the handler writes. Poll the body instead: the
		// handler flushes after every event, so the content is available as
		// soon as it is produced.
		reader := newRecorderReader(rec)
		for {
			frame, err := reader.next(timeout)
			if err != nil {
				return
			}
			frames <- frame
		}
	}()

	stop := func() {
		cancel()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Error("handler did not return after the request context was cancelled")
		}
	}
	return frames, stop
}

// recorderReader incrementally reads an httptest.ResponseRecorder's body.
//
// A ResponseRecorder is not a stream, so this polls its buffer for new complete
// SSE frames. It is test scaffolding, not production code: the real stream is
// read over a socket.
type recorderReader struct {
	rec  *httptest.ResponseRecorder
	seen int
}

func newRecorderReader(rec *httptest.ResponseRecorder) *recorderReader {
	return &recorderReader{rec: rec}
}

func (r *recorderReader) next(timeout time.Duration) (sseFrame, error) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		body := r.rec.Body.String()
		if len(body) > r.seen {
			chunk := body[r.seen:]
			// A complete frame ends with a blank line.
			if idx := strings.Index(chunk, "\n\n"); idx >= 0 {
				r.seen += idx + 2
				return parseFrame(chunk[:idx]), nil
			}
		}
		time.Sleep(5 * time.Millisecond)
	}
	return sseFrame{}, io.EOF
}

func parseFrame(raw string) sseFrame {
	var f sseFrame
	var dataLines []string
	for _, line := range strings.Split(raw, "\n") {
		switch {
		case strings.HasPrefix(line, "event:"):
			f.Name = strings.TrimSpace(strings.TrimPrefix(line, "event:"))
		case strings.HasPrefix(line, "data:"):
			dataLines = append(dataLines, strings.TrimSpace(strings.TrimPrefix(line, "data:")))
		case strings.HasPrefix(line, ":"):
			f.IsRaw = true
		}
	}
	f.Data = strings.Join(dataLines, "\n")
	return f
}

func newEventServer(t *testing.T, hub *events.Hub) *Server {
	t.Helper()

	// A gallery so the index reports a non-zero count.
	g := &models.Gallery{
		GID:          1234567,
		Title:        "Sample",
		DirName:      "1234567-Sample",
		Availability: models.AvailOK,
		MetaSource:   models.MetaSourceLocalOnly,
		OnDisk:       true,
		PagesFound:   1,
		Anomalies:    []string{},
		Pages: []models.Page{
			{Index: 0, Filename: "00000001.jpg", Ext: ".jpg", Size: 1, MTimeMS: 1, URL: "/img/1234567/0"},
		},
	}
	idx := index.Build(index.BuildInput{
		Scanned: &scan.Result{Galleries: []*models.Gallery{g}},
	})

	srv, err := New(Options{
		Store:                index.NewStore(idx),
		Thumbs:               nil,
		Logger:               slog.New(slog.NewTextHandler(io.Discard, nil)),
		Events:               hub,
		AllowUnauthenticated: true,
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return srv
}

func TestEventStreamSendsHelloImmediately(t *testing.T) {
	hub := events.NewHub()
	defer hub.Close()
	srv := newEventServer(t, hub)

	frames, stop := openStream(t, srv.Handler(), "/api/v1/events", 3*time.Second)
	defer stop()

	select {
	case frame := <-frames:
		// The immediate event is what lets a client tell a working stream from
		// one held by a buffering proxy: a buffered stream produces nothing at
		// all, with no error anywhere.
		if frame.Name != events.EventHello {
			t.Fatalf("first frame: got event %q, want %q", frame.Name, events.EventHello)
		}
		var payload events.Event
		if err := json.Unmarshal([]byte(frame.Data), &payload); err != nil {
			t.Fatalf("hello payload is not JSON: %v (%q)", err, frame.Data)
		}
		if payload.Galleries != 1 {
			t.Errorf("hello galleries: got %d, want 1", payload.Galleries)
		}
		if payload.IndexAtMS == 0 {
			t.Error("hello should carry the index timestamp")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("no hello event: a client could not distinguish this from a buffered stream")
	}
}

func TestEventStreamDeliversBroadcasts(t *testing.T) {
	hub := events.NewHub()
	defer hub.Close()
	srv := newEventServer(t, hub)

	frames, stop := openStream(t, srv.Handler(), "/api/v1/events", 5*time.Second)
	defer stop()

	// Drain hello.
	select {
	case <-frames:
	case <-time.After(3 * time.Second):
		t.Fatal("no hello event")
	}

	// Wait for the subscriber to be registered before broadcasting, or the
	// event is published into the void and the test becomes flaky.
	deadline := time.Now().Add(2 * time.Second)
	for hub.Subscribers() == 0 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if hub.Subscribers() == 0 {
		t.Fatal("the handler never subscribed")
	}

	hub.Broadcast(events.Event{
		Name:      events.EventIndexChanged,
		Galleries: 2,
		Added:     []int64{9999999},
		Changed:   []int64{1234567},
		Reason:    "filesystem_change",
	})

	select {
	case frame := <-frames:
		if frame.Name != events.EventIndexChanged {
			t.Fatalf("event name: got %q", frame.Name)
		}
		var payload events.Event
		if err := json.Unmarshal([]byte(frame.Data), &payload); err != nil {
			t.Fatalf("payload is not JSON: %v (%q)", err, frame.Data)
		}
		if payload.Galleries != 2 {
			t.Errorf("galleries: got %d", payload.Galleries)
		}
		if len(payload.Added) != 1 || payload.Added[0] != 9999999 {
			t.Errorf("added: got %v", payload.Added)
		}
		if len(payload.Changed) != 1 || payload.Changed[0] != 1234567 {
			t.Errorf("changed: got %v", payload.Changed)
		}
		if payload.Reason != "filesystem_change" {
			t.Errorf("reason: got %q", payload.Reason)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("the broadcast never arrived on the stream")
	}
}

// The stream must end when the client disconnects, releasing the subscriber.
// A leaked subscriber is a goroutine and a queue that outlive the request.
func TestEventStreamReleasesSubscriberOnDisconnect(t *testing.T) {
	hub := events.NewHub()
	defer hub.Close()
	srv := newEventServer(t, hub)

	frames, stop := openStream(t, srv.Handler(), "/api/v1/events", 3*time.Second)
	select {
	case <-frames:
	case <-time.After(3 * time.Second):
		t.Fatal("no hello event")
	}

	deadline := time.Now().Add(2 * time.Second)
	for hub.Subscribers() == 0 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if hub.Subscribers() != 1 {
		t.Fatalf("subscribers: got %d, want 1", hub.Subscribers())
	}

	stop()

	deadline = time.Now().Add(2 * time.Second)
	for hub.Subscribers() != 0 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if got := hub.Subscribers(); got != 0 {
		t.Errorf("subscriber leaked after disconnect: %d still registered", got)
	}
}

// Without a hub, the endpoint must say so rather than holding a stream open
// that will never produce anything. A client cannot tell an idle stream from a
// broken one, so silence would be the wrong answer.
func TestEventStreamWithoutHubIsRejected(t *testing.T) {
	srv := newEventServer(t, nil)

	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/events", nil))

	if rec.Code != http.StatusNotImplemented {
		t.Fatalf("status: got %d, want 501", rec.Code)
	}
	var body apiError
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("error body is not JSON: %s", rec.Body.String())
	}
	if body.Error.Code != "unsupported" {
		t.Errorf("error code: got %q", body.Error.Code)
	}
}

func TestMetaAdvertisesSSEOnlyWhenAvailable(t *testing.T) {
	fetchMeta := func(srv *Server) map[string]any {
		t.Helper()
		rec := httptest.NewRecorder()
		srv.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/meta", nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("meta status: got %d", rec.Code)
		}
		return decodeJSON[map[string]any](t, rec)
	}

	withHub := newEventServer(t, events.NewHub())
	meta := fetchMeta(withHub)
	features, _ := meta["features"].(map[string]any)
	if features["sse"] != true {
		t.Errorf("features.sse: got %v, want true when a hub exists", features["sse"])
	}

	// A server without a hub must not advertise a stream it cannot serve: a
	// client cannot distinguish an idle stream from a missing one.
	without := newEventServer(t, nil)
	meta = fetchMeta(without)
	features, _ = meta["features"].(map[string]any)
	if features["sse"] != false {
		t.Errorf("features.sse: got %v, want false without a hub", features["sse"])
	}
}

// The stream is a content route: an anonymous caller must not be able to watch
// the library change.
func TestEventStreamRequiresASession(t *testing.T) {
	mgr, err := auth.New(auth.Options{
		Mode:    auth.ModeToken,
		Token:   "t",
		KeyPath: t.TempDir() + "/k",
	})
	if err != nil {
		t.Fatal(err)
	}
	hub := events.NewHub()
	defer hub.Close()

	idx := index.Build(index.BuildInput{Scanned: &scan.Result{}})
	srv, err := New(Options{
		Store:  index.NewStore(idx),
		Auth:   mgr,
		Logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
		Events: hub,
	})
	if err != nil {
		t.Fatal(err)
	}

	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/events", nil))
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("status: got %d, want 401", rec.Code)
	}
	// And it must not have registered a subscriber on the way to rejecting.
	if got := hub.Subscribers(); got != 0 {
		t.Errorf("rejected request left %d subscribers", got)
	}
}

func TestSSEWireFormat(t *testing.T) {
	var sb strings.Builder
	w := &flushRecorder{header: http.Header{}, body: &sb}

	event := events.Event{
		Name:         events.EventIndexChanged,
		IndexAtMS:    1700000000000,
		SnapshotAtMS: 1699999000000,
		Galleries:    7,
		Added:        []int64{1, 2},
		Reason:       "filesystem_change",
	}
	if err := writeSSE(w, event); err != nil {
		t.Fatalf("writeSSE: %v", err)
	}

	out := sb.String()
	if !strings.HasPrefix(out, "event: index_changed\n") {
		t.Errorf("missing event line: %q", out)
	}
	if !strings.HasSuffix(out, "\n\n") {
		t.Errorf("frame must end with a blank line: %q", out)
	}
	if !strings.Contains(out, "data: {") {
		t.Errorf("missing data line: %q", out)
	}

	// The data line must be valid JSON on its own.
	var payload events.Event
	data := strings.TrimPrefix(strings.Split(strings.TrimSpace(out), "\n")[1], "data: ")
	if err := json.Unmarshal([]byte(data), &payload); err != nil {
		t.Fatalf("data line is not JSON: %v (%q)", err, data)
	}
	if payload.Galleries != 7 {
		t.Errorf("galleries: got %d", payload.Galleries)
	}
}

// A multi-line payload must be split across data lines, or everything after
// the first newline is lost.
func TestSplitLinesHandlesMultilinePayloads(t *testing.T) {
	got := splitLines([]byte("{\n\"a\":1\n}"))
	want := []string{"{", `"a":1`, "}"}
	if len(got) != len(want) {
		t.Fatalf("got %q, want %q", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %q, want %q", got, want)
		}
	}

	// A single-line payload, which is what json.Marshal normally produces.
	got = splitLines([]byte(`{"a":1}`))
	if len(got) != 1 || got[0] != `{"a":1}` {
		t.Errorf("single line: got %q", got)
	}

	// An empty payload must not produce a spurious empty line.
	if got := splitLines(nil); len(got) != 0 {
		t.Errorf("empty: got %q", got)
	}
}

// flushRecorder is a minimal ResponseWriter that records what is written and
// exposes Flush, which the SSE path requires.
type flushRecorder struct {
	header http.Header
	body   *strings.Builder
	status int
}

func (f *flushRecorder) Header() http.Header { return f.header }
func (f *flushRecorder) Write(b []byte) (int, error) {
	return f.body.Write(b)
}
func (f *flushRecorder) WriteHeader(code int) { f.status = code }
func (f *flushRecorder) Flush()               {}

var _ http.Flusher = (*flushRecorder)(nil)
var _ = bufio.NewReader
