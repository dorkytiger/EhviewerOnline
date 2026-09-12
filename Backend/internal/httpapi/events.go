package httpapi

import (
	"fmt"
	"net/http"
	"time"

	"github.com/warren/ehviewer-webd/internal/events"
)

// SSE keepalive and deadline tuning.
const (
	// sseHeartbeat keeps the connection alive through proxies that close idle
	// connections, and gives the client a liveness signal. It is a comment
	// line rather than an event so it cannot be mistaken for a change.
	sseHeartbeat = 15 * time.Second

	// sseMaxLifetime bounds how long one connection may live. Long-lived
	// streams are exactly the connections that leak when something upstream
	// misbehaves, and a client that reconnects is cheap. It also guarantees the
	// session is re-checked periodically on a connection that was authorised
	// once.
	sseMaxLifetime = 30 * time.Minute

	// sseWriteTimeout bounds a single write. A client that stops reading must
	// not pin a goroutine forever.
	sseWriteTimeout = 10 * time.Second
)

// handleEvents streams index changes as server-sent events.
//
// ## Why this is more than a nicety
//
// The backend already watches the filesystem and rebuilds within a couple of
// seconds. Without a stream the client has to poll, and polling a service that
// sits behind a bandwidth-limited tunnel is exactly the wrong shape: either it
// polls too rarely and the library looks stale, or it polls often and spends
// the tunnel budget on empty answers.
//
// ## The one thing that will silently break this
//
// A reverse proxy that buffers responses will accept the connection, return
// 200, and then hold the stream — the client sees a live connection that never
// produces an event, with no error anywhere. Nginx needs
// `proxy_buffering off;` and Caddy needs `flush_interval -1`. The handler does
// the part it can control: it writes a `hello` event immediately and flushes,
// so a client can tell "connected and quiet" from "connected but stuck behind a
// buffer" by whether the first event arrived at all.
//
// ## Authentication
//
// The route sits behind the same session middleware as every other content
// route. `EventSource` cannot set request headers, so on web the browser's
// HttpOnly cookie is the only credential that works — which is why the README
// requires same-origin deployment.
func (s *Server) handleEvents(w http.ResponseWriter, r *http.Request) {
	setSecurityHeaders(w)

	if s.events == nil {
		writeError(w, http.StatusNotImplemented, "unsupported",
			"this server was started without an event hub")
		return
	}

	flusher, ok := w.(http.Flusher)
	if !ok {
		// Without flushing, every event would sit in a buffer until the
		// connection closed, which for a stream means never.
		writeError(w, http.StatusInternalServerError, "internal",
			"streaming is not supported by this connection")
		return
	}

	// A cached stream is worse than no stream: an intermediary would replay one
	// client's events to another.
	w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Connection", "keep-alive")
	// Tell nginx not to buffer this response, so an operator who forgets the
	// proxy directive gets a warning in the log rather than silent breakage.
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)

	sub := s.events.Subscribe()
	defer sub.Close()

	stats := s.store.Load().Stats()
	s.log.Debug("event stream opened",
		"remote", r.RemoteAddr, "subscribers", s.events.Subscribers())

	// An immediate event, so the client can distinguish a working stream from
	// one held by a buffering proxy.
	if err := writeSSE(w, events.Event{
		Name:         events.EventHello,
		IndexAtMS:    stats.IndexedAtMS,
		SnapshotAtMS: stats.SnapshotAtMS,
		Galleries:    stats.Galleries,
	}); err != nil {
		return
	}
	flusher.Flush()

	heartbeat := time.NewTicker(sseHeartbeat)
	defer heartbeat.Stop()

	deadline := time.NewTimer(sseMaxLifetime)
	defer deadline.Stop()

	ctx := r.Context()
	for {
		select {
		case <-ctx.Done():
			// The client went away. This is the normal way a stream ends.
			return

		case <-deadline.C:
			// Ask the client to come back; a fresh connection re-checks the
			// session and any proxies in between get a clean connection.
			refreshWriteDeadline(w, sseWriteTimeout)
			_ = writeSSEComment(w, "reconnect")
			flusher.Flush()
			return

		case <-sub.Done():
			return

		case event := <-sub.C():
			refreshWriteDeadline(w, sseWriteTimeout)
			if err := writeSSE(w, event); err != nil {
				s.log.Debug("event stream write failed", "error", err)
				return
			}
			flusher.Flush()

		case <-heartbeat.C:
			refreshWriteDeadline(w, sseWriteTimeout)
			if err := writeSSEComment(w, "keepalive"); err != nil {
				return
			}
			flusher.Flush()
		}
	}
}

// writeSSE renders one event in the SSE wire format.
//
// The format is: an optional `event:` line, one or more `data:` lines, then a
// blank line. Every newline inside the JSON must be its own `data:` line, or
// the payload is truncated at the first newline — and `json.Marshal` output is
// normally single-line, but escaping rules make that an assumption worth not
// relying on.
func writeSSE(w http.ResponseWriter, event events.Event) error {
	payload, err := event.Marshal()
	if err != nil {
		return err
	}
	name := event.Name
	if name == "" {
		name = events.EventIndexChanged
	}

	if err := writeLine(w, "event: "+name+"\n"); err != nil {
		return err
	}
	for _, line := range splitLines(payload) {
		if err := writeLine(w, "data: "+line+"\n"); err != nil {
			return err
		}
	}
	return writeLine(w, "\n")
}

// writeSSEComment writes a comment line, used for keepalives.
func writeSSEComment(w http.ResponseWriter, text string) error {
	return writeLine(w, ": "+text+"\n\n")
}

// writeLine writes one chunk of the stream.
//
// No per-write deadline is set here on purpose. The server runs with
// WriteTimeout disabled, because a single global write timeout cannot serve
// both a long-lived SSE stream and a large image download. Instead each handler
// bounds itself with ResponseController; see refreshWriteDeadline.
func writeLine(w http.ResponseWriter, s string) error {
	_, err := fmt.Fprint(w, s)
	return err
}

// refreshWriteDeadline extends the connection's write deadline.
//
// This is how a long-lived stream coexists with per-request timeouts without a
// global WriteTimeout that would either kill the stream or fail to protect
// anything. A ResponseWriter without deadline support is not an error: the
// stream then relies on the client's context, the heartbeat, and the maximum
// lifetime.
func refreshWriteDeadline(w http.ResponseWriter, d time.Duration) {
	rc := http.NewResponseController(w)
	// The error is deliberately ignored: unsupported is a normal condition for
	// wrapped writers and has no useful remedy here.
	_ = rc.SetWriteDeadline(time.Now().Add(d))
}

// splitLines splits a JSON payload into lines, dropping the trailing newline a
// naive split would produce.
func splitLines(payload []byte) []string {
	var out []string
	start := 0
	for i, b := range payload {
		if b == '\n' {
			out = append(out, string(payload[start:i]))
			start = i + 1
		}
	}
	if start < len(payload) {
		out = append(out, string(payload[start:]))
	}
	return out
}
