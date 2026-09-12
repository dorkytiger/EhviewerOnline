// Package httpapi exposes the index over HTTP.
//
// Route table (all content routes require a session; see the design doc §6):
//
//	GET  /healthz                     unauthenticated liveness probe
//	GET  /readyz                      index-loaded probe
//	POST /api/v1/auth/login           exchange a token for a session cookie
//	POST /api/v1/auth/logout
//	GET  /api/v1/auth/me
//	GET  /api/v1/meta                 freshness + feature flags
//	GET  /api/v1/facets               filter dimensions
//	GET  /api/v1/galleries            paged list
//	GET  /api/v1/galleries/{gid}      one gallery, with its page list
//	POST /api/v1/admin/reindex        force a rebuild (loopback callers only)
//	GET  /img/{gid}/{index}           original page image
//	GET  /thumb/{gid}                 cover thumbnail (JPEG)
//
// Design notes that matter more than the routing:
//
//   - The image handlers never build a path from user input. The gid must
//     resolve in the index and the page index must be within that gallery's
//     page slice; the filename comes from the scan. That removes directory
//     traversal as a category rather than filtering for it.
//   - A missing directory is a 404, but an orphan DB row is a normal 200 with
//     availability "missing", so the client can distinguish "no such gallery"
//     from "not synced yet".
package httpapi

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"hash/fnv"
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/warren/ehviewer-webd/internal/auth"
	"github.com/warren/ehviewer-webd/internal/events"
	"github.com/warren/ehviewer-webd/internal/index"
	"github.com/warren/ehviewer-webd/internal/models"
	"github.com/warren/ehviewer-webd/internal/scan"
	"github.com/warren/ehviewer-webd/internal/thumbcache"
)

// Version is stamped into /api/v1/meta.
const Version = "0.1.0"

// Server serves the API.
type Server struct {
	store  *index.Store
	auth   *auth.Manager
	thumbs *thumbcache.Cache
	log    *slog.Logger

	// Roots is retained for the path containment check on image reads.
	roots []string
	// RootsConfigured records whether the operator declared roots. When they
	// did not, containment cannot be checked and is skipped with a warning.
	rootsConfigured bool

	reindex ReindexFunc
	events  *events.Hub
	started time.Time
}

// ReindexFunc rebuilds the index. Wired by main so the HTTP layer does not
// depend on the watcher.
type ReindexFunc func(ctx context.Context) (*index.Index, error)

// Options configures a Server.
type Options struct {
	Store           *index.Store
	Auth            *auth.Manager
	Thumbs          *thumbcache.Cache
	Logger          *slog.Logger
	Roots           []string
	RootsConfigured bool
	Reindex         ReindexFunc

	// Events is the change hub behind /api/v1/events. A nil hub reports the
	// SSE feature as unsupported rather than serving a stream that never
	// produces anything, which a client could not distinguish from an idle
	// server.
	Events *events.Hub

	// AllowUnauthenticated serves everything without a session.
	//
	// This exists for httptest-based tests, which drive the real handler and
	// therefore need a way in without going through the login flow. It is not
	// reachable from configuration: config.Validate refuses auth.mode="none"
	// on a non-loopback listener, and cmdServe never sets this.
	AllowUnauthenticated bool
}

// New builds a Server.
func New(opts Options) (*Server, error) {
	if opts.Store == nil {
		return nil, errors.New("httpapi: Store is required")
	}
	if opts.Auth == nil {
		if !opts.AllowUnauthenticated {
			return nil, errors.New("httpapi: Auth is required")
		}
		// A manager in "none" mode authenticates everything.
		m, err := auth.New(auth.Options{Mode: auth.ModeNone})
		if err != nil {
			return nil, err
		}
		opts.Auth = m
	}
	log := opts.Logger
	if log == nil {
		log = slog.Default()
	}
	return &Server{
		store:           opts.Store,
		auth:            opts.Auth,
		thumbs:          opts.Thumbs,
		log:             log,
		roots:           opts.Roots,
		rootsConfigured: opts.RootsConfigured,
		reindex:         opts.Reindex,
		events:          opts.Events,
		started:         time.Now(),
	}, nil
}

// Handler returns the fully wired http.Handler.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()

	// Unauthenticated: no business data, and no hint that anything else exists.
	mux.HandleFunc("GET /healthz", s.handleHealthz)
	mux.HandleFunc("GET /readyz", s.handleReadyz)

	// Authentication endpoints manage the cookie, so they cannot require one.
	mux.HandleFunc("POST /api/v1/auth/login", s.handleLogin)
	mux.HandleFunc("POST /api/v1/auth/logout", s.handleLogout)
	mux.HandleFunc("GET /api/v1/auth/me", s.handleMe)

	// Everything below can reveal content and is wrapped in the auth
	// middleware, images and the SSE stream included.
	content := http.NewServeMux()
	content.HandleFunc("GET /api/v1/meta", s.handleMeta)
	content.HandleFunc("GET /api/v1/facets", s.handleFacets)
	content.HandleFunc("GET /api/v1/galleries", s.handleGalleries)
	content.HandleFunc("GET /api/v1/galleries/{gid}", s.handleGallery)
	content.HandleFunc("GET /api/v1/events", s.handleEvents)
	content.HandleFunc("POST /api/v1/admin/reindex", s.handleReindex)
	content.HandleFunc("GET /img/{gid}/{index}", s.handleImage)
	content.HandleFunc("GET /thumb/{gid}", s.handleThumb)

	mux.Handle("/api/v1/meta", s.auth.Middleware(content))
	mux.Handle("/api/v1/facets", s.auth.Middleware(content))
	mux.Handle("/api/v1/galleries", s.auth.Middleware(content))
	mux.Handle("/api/v1/galleries/", s.auth.Middleware(content))
	mux.Handle("/api/v1/events", s.auth.Middleware(content))
	mux.Handle("/api/v1/admin/", s.auth.Middleware(content))
	mux.Handle("/img/", s.auth.Middleware(content))
	mux.Handle("/thumb/", s.auth.Middleware(content))

	// The SSE stream is long-lived. The logging middleware's response recorder
	// forwards Flush, which is what keeps the stream unbuffered; see its Flush
	// method.
	return s.recoverMiddleware(s.logMiddleware(mux))
}

// --- middleware ------------------------------------------------------------

func (s *Server) recoverMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if rec := recover(); rec != nil {
				s.log.Error("panic serving request",
					"panic", fmt.Sprint(rec),
					"method", r.Method,
					"path", r.URL.Path,
				)
				http.Error(w, "internal error", http.StatusInternalServerError)
			}
		}()
		next.ServeHTTP(w, r)
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
	bytes  int64
}

func (sr *statusRecorder) WriteHeader(code int) {
	sr.status = code
	sr.ResponseWriter.WriteHeader(code)
}

func (sr *statusRecorder) Write(b []byte) (int, error) {
	if sr.status == 0 {
		sr.status = http.StatusOK
	}
	n, err := sr.ResponseWriter.Write(b)
	sr.bytes += int64(n)
	return n, err
}

// Flush keeps the SSE path working when the recorder sits in front of it.
func (sr *statusRecorder) Flush() {
	if f, ok := sr.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (s *Server) logMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w}
		next.ServeHTTP(rec, r)

		status := rec.status
		if status == 0 {
			status = http.StatusOK
		}
		level := slog.LevelInfo
		switch {
		case status >= 500:
			level = slog.LevelError
		case status == http.StatusUnauthorized, status == http.StatusForbidden:
			// Expected noise from scanners; keep it out of info-level logs.
			level = slog.LevelDebug
		case status >= 400:
			level = slog.LevelWarn
		}
		s.log.Log(r.Context(), level, "request",
			"method", r.Method,
			"path", r.URL.Path,
			"status", status,
			"bytes", rec.bytes,
			"duration_ms", time.Since(start).Milliseconds(),
		)
	})
}

// setSecurityHeaders applies the headers that matter for a single-origin app
// serving user-visible images.
func setSecurityHeaders(w http.ResponseWriter) {
	h := w.Header()
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("X-Frame-Options", "DENY")
}

// --- health ----------------------------------------------------------------

func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(map[string]any{"status": "ok"})
}

func (s *Server) handleReadyz(w http.ResponseWriter, r *http.Request) {
	idx := s.store.Load()
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	if idx == nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		_ = json.NewEncoder(w).Encode(map[string]any{"ready": false})
		return
	}
	_ = json.NewEncoder(w).Encode(map[string]any{"ready": true, "galleries": idx.Len()})
}

// --- auth endpoints --------------------------------------------------------

type loginRequest struct {
	Token string `json:"token"`
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	setSecurityHeaders(w)
	w.Header().Set("Cache-Control", "no-store")

	if s.auth.Mode() == auth.ModeNone {
		writeError(w, http.StatusBadRequest, "auth_disabled",
			"authentication is disabled on this server")
		return
	}

	// Cap the body: a token request is tiny, and an unbounded body is a free
	// memory amplifier.
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	var req loginRequest
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "malformed request body")
		return
	}

	if err := s.auth.CheckToken(req.Token); err != nil {
		// Deliberately uniform: no distinction between "wrong token" and
		// "no token configured beyond the guard above".
		s.log.Warn("failed login attempt")
		writeError(w, http.StatusUnauthorized, "unauthorized", "invalid token")
		return
	}

	value, err := s.auth.Issue()
	if err != nil {
		s.log.Error("cannot issue session", "error", err)
		writeError(w, http.StatusInternalServerError, "internal", "cannot issue session")
		return
	}
	s.auth.SetCookie(w, value)
	writeJSON(w, http.StatusOK, map[string]any{
		"authenticated":   true,
		"expires_in_secs": int(s.auth.TTL().Seconds()),
	})
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	setSecurityHeaders(w)
	s.auth.ClearCookie(w)
	writeJSON(w, http.StatusOK, map[string]any{"authenticated": false})
}

func (s *Server) handleMe(w http.ResponseWriter, r *http.Request) {
	setSecurityHeaders(w)
	w.Header().Set("Cache-Control", "no-store")

	if s.auth.Mode() == auth.ModeNone {
		writeJSON(w, http.StatusOK, map[string]any{
			"authenticated": true,
			"auth_mode":     string(auth.ModeNone),
		})
		return
	}
	p, err := s.auth.SessionFrom(r)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "unauthorized", "no valid session")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"authenticated": true,
		"auth_mode":     string(auth.ModeToken),
		"expires_at_ms": p.Expires * 1000,
	})
}

// --- meta and facets -------------------------------------------------------

func (s *Server) handleMeta(w http.ResponseWriter, r *http.Request) {
	idx := s.store.Load()
	stats := idx.Stats()
	writeJSON(w, http.StatusOK, map[string]any{
		"version":        Version,
		"server_time_ms": time.Now().UnixMilli(),
		"uptime_secs":    int(time.Since(s.started).Seconds()),
		"index":          stats,
		"snapshot_file":  filepath.Base(stats.SnapshotPath),
		"roots":          s.roots,
		"warnings":       idx.Warnings(),
		"skipped_dirs":   skippedDTO(idx.Skipped()),
		"features": map[string]bool{
			// The exported DB has no Gallery_Tags table, so tag filtering is
			// impossible from a snapshot (design doc §2.5). The client uses
			// this to hide the tag filter rather than showing one that always
			// returns nothing.
			"tags":       false,
			"thumbnails": s.thumbs != nil,
			// Reported from the actual hub, not from a build flag: a server
			// started without one must not advertise a stream it cannot serve,
			// because a client cannot tell an idle stream from a missing one.
			"sse": s.events != nil,
		},
		"thumb_stats": s.thumbStats(),
	})
}

func (s *Server) thumbStats() any {
	if s.thumbs == nil {
		return nil
	}
	return s.thumbs.Stats()
}

func skippedDTO(skipped []scan.Skip) []map[string]string {
	out := make([]map[string]string, 0, len(skipped))
	// Cap the list: a misconfigured root could produce one entry per file.
	const limit = 50
	for i, s := range skipped {
		if i >= limit {
			break
		}
		out = append(out, map[string]string{"path": s.Path, "reason": s.Reason})
	}
	return out
}

func (s *Server) handleFacets(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.store.Load().Facets())
}

// --- gallery list ----------------------------------------------------------

func (s *Server) handleGalleries(w http.ResponseWriter, r *http.Request) {
	idx := s.store.Load()
	q := r.URL.Query()

	query := models.Query{
		Text:         strings.TrimSpace(q.Get("q")),
		Label:        q.Get("label"),
		Language:     q.Get("language"),
		Availability: q.Get("availability"),
		Sort:         q.Get("sort"),
		// Tag dimensions are repeated parameters — ?artist=a&artist=b — and
		// mean "either", because a gallery can have several artists and a user
		// picking two of them is not asking for the intersection.
		Artists:  cleanTagParams(q["artist"]),
		Groups:   cleanTagParams(q["group"]),
		Series:   cleanTagParams(q["series"]),
		Events:   cleanTagParams(q["event"]),
		Editions: cleanTagParams(q["edition"]),
	}
	if v := q.Get("category"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil {
			writeError(w, http.StatusBadRequest, "bad_request", "category must be an integer")
			return
		}
		query.Category = &n
	}
	if v := q.Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil {
			writeError(w, http.StatusBadRequest, "bad_request", "limit must be an integer")
			return
		}
		query.Limit = n
	}
	if !validSort(query.Sort) {
		writeError(w, http.StatusBadRequest, "bad_request",
			"sort must be one of: "+strings.Join(validSorts, ", "))
		return
	}

	fingerprint := index.FilterFingerprint(query)
	offset, err := index.DecodeCursor(q.Get("cursor"), fingerprint)
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_cursor", err.Error())
		return
	}
	query.Offset = offset

	res := idx.Query(query)
	limit := query.Limit
	if limit <= 0 {
		limit = index.DefaultLimit
	}

	var nextCursor string
	if res.Total > offset+len(res.Items) {
		nextCursor = index.EncodeCursor(offset+len(res.Items), fingerprint)
	}

	items := make([]GalleryDTO, 0, len(res.Items))
	for _, g := range res.Items {
		items = append(items, toDTO(g))
	}

	stats := idx.Stats()
	writeJSON(w, http.StatusOK, galleryListDTO{
		Items:        items,
		NextCursor:   nextCursor,
		Total:        res.Total,
		Limit:        limit,
		IndexedAtMS:  stats.IndexedAtMS,
		SnapshotAtMS: stats.SnapshotAtMS,
	})
}

var validSorts = []string{
	index.SortTimeDesc, index.SortTimeAsc, index.SortTitleAsc,
	index.SortRatingDesc, index.SortPagesDesc, index.SortGIDDesc, index.SortRandom,
}

func validSort(s string) bool {
	if s == "" {
		return true
	}
	for _, v := range validSorts {
		if s == v {
			return true
		}
	}
	return false
}

func (s *Server) handleGallery(w http.ResponseWriter, r *http.Request) {
	gid, err := strconv.ParseInt(r.PathValue("gid"), 10, 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "gid must be an integer")
		return
	}
	g, ok := s.store.Load().Get(gid)
	if !ok {
		writeError(w, http.StatusNotFound, "not_found", "no such gallery")
		return
	}

	detail := toDetailDTO(g)
	// Neighbours in gid order, for the reader's "next book" affordance.
	all := s.store.Load().All()
	for i, cand := range all {
		if cand.GID != gid {
			continue
		}
		if i > 0 {
			detail.PrevGID = all[i-1].GID
		}
		if i+1 < len(all) {
			detail.NextGID = all[i+1].GID
		}
		break
	}
	writeJSON(w, http.StatusOK, detail)
}

// --- images ----------------------------------------------------------------

func (s *Server) handleImage(w http.ResponseWriter, r *http.Request) {
	setSecurityHeaders(w)

	gid, err := strconv.ParseInt(r.PathValue("gid"), 10, 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "gid must be an integer")
		return
	}
	pageIndex, err := strconv.Atoi(r.PathValue("index"))
	if err != nil || pageIndex < 0 {
		writeError(w, http.StatusBadRequest, "bad_request", "index must be a non-negative integer")
		return
	}

	g, ok := s.store.Load().Get(gid)
	if !ok {
		writeError(w, http.StatusNotFound, "not_found", "no such gallery")
		return
	}
	// The page slice is the authority. The filename is never derived from the
	// request, which is what makes traversal impossible here.
	if pageIndex >= len(g.Pages) {
		writeError(w, http.StatusNotFound, "not_found", "no such page")
		return
	}
	page := g.Pages[pageIndex]

	path := filepath.Join(g.DirPath, page.Filename)
	if err := s.checkContained(path); err != nil {
		s.log.Error("refusing to serve a path outside the configured roots",
			"gid", gid, "path", path, "error", err)
		writeError(w, http.StatusInternalServerError, "internal", "path rejected")
		return
	}

	f, err := os.Open(path)
	if err != nil {
		writeError(w, http.StatusNotFound, "not_found", "image is not readable")
		return
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal", "cannot stat image")
		return
	}

	w.Header().Set("Content-Type", contentTypeForExt(page.Ext))
	w.Header().Set("Cache-Control", "private, max-age=31536000, immutable")
	w.Header().Set("Content-Disposition", "inline")
	// http.ServeContent *consumes* ETag but never generates one, so without
	// this the reader would re-download every page on each revalidation. A
	// size+mtime tag is sufficient: the synced files are immutable in practice,
	// and a re-download always changes at least the mtime.
	w.Header().Set("ETag", fileETag(fi))

	// The server runs without a global WriteTimeout, because one value cannot
	// serve both this and a long-lived SSE stream. Bound the write here: a
	// large page over a slow tunnel needs minutes, but not forever.
	//
	// A ResponseWriter without deadline support is fine; the read is then
	// bounded only by the client going away.
	_ = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(imageWriteTimeout))

	// ServeContent handles Range, If-Modified-Since and If-None-Match and sets
	// a correct Content-Length, so byte-range seeking in the reader works.
	http.ServeContent(w, r, page.Filename, fi.ModTime(), f)
}

// imageWriteTimeout bounds a single image response.
const imageWriteTimeout = 10 * time.Minute

// fileETag builds a weak-ish strong validator from the file size and mtime.
//
// FNV-1a over the size and nanosecond mtime is enough here: the inputs are
// already the only things that change when a page is re-downloaded, and the
// alternative (hashing file contents) would read every byte of a 5 MB image on
// every request.
func fileETag(fi os.FileInfo) string {
	h := fnv.New64a()
	var buf [16]byte
	binary.LittleEndian.PutUint64(buf[0:8], uint64(fi.Size()))
	binary.LittleEndian.PutUint64(buf[8:16], uint64(fi.ModTime().UnixNano()))
	_, _ = h.Write(buf[:])
	return `"` + strconv.FormatUint(h.Sum64(), 16) + `"`
}

func (s *Server) handleThumb(w http.ResponseWriter, r *http.Request) {
	setSecurityHeaders(w)

	gid, err := strconv.ParseInt(r.PathValue("gid"), 10, 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "gid must be an integer")
		return
	}
	g, ok := s.store.Load().Get(gid)
	if !ok {
		writeError(w, http.StatusNotFound, "not_found", "no such gallery")
		return
	}
	if len(g.Pages) == 0 {
		writeError(w, http.StatusNotFound, "no_cover", "this gallery has no local pages")
		return
	}

	page := g.Pages[0]
	srcPath := filepath.Join(g.DirPath, page.Filename)
	if err := s.checkContained(srcPath); err != nil {
		writeError(w, http.StatusInternalServerError, "internal", "path rejected")
		return
	}

	// No cache configured: fall back to serving the original so the UI still
	// works, just heavier.
	if s.thumbs == nil {
		f, err := os.Open(srcPath)
		if err != nil {
			writeError(w, http.StatusNotFound, "not_found", "cover is not readable")
			return
		}
		defer f.Close()
		fi, _ := f.Stat()
		mod := time.Now()
		if fi != nil {
			mod = fi.ModTime()
		}
		w.Header().Set("Content-Type", contentTypeForExt(page.Ext))
		w.Header().Set("Cache-Control", "private, max-age=3600")
		http.ServeContent(w, r, page.Filename, mod, f)
		return
	}

	// Bound render time: on a cache miss this decodes an arbitrary image, and
	// a slow request must not hold a worker forever.
	ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
	defer cancel()

	key := fmt.Sprintf("thumb:%d", gid)
	jpg, err := s.thumbs.Get(ctx, key, srcPath, page.MTimeMS)
	if err != nil {
		// An oversized or corrupt first page should not break the list. Fall
		// back to any later page before giving up.
		for _, alt := range g.Pages[1:] {
			altPath := filepath.Join(g.DirPath, alt.Filename)
			if s.checkContained(altPath) != nil {
				continue
			}
			jpg, err = s.thumbs.Get(ctx, key, altPath, alt.MTimeMS)
			if err == nil {
				break
			}
		}
		if err != nil {
			if errors.Is(err, thumbcache.ErrTooLarge) {
				writeError(w, http.StatusUnprocessableEntity, "thumb_too_large",
					"the cover image is too large to thumbnail")
				return
			}
			writeError(w, http.StatusNotFound, "no_cover", "cannot render a cover")
			return
		}
	}

	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("Cache-Control", "private, max-age=31536000, immutable")
	_, _ = w.Write(jpg)
}

func contentTypeForExt(ext string) string {
	switch strings.ToLower(ext) {
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".png":
		return "image/png"
	case ".gif":
		return "image/gif"
	case ".webp":
		return "image/webp"
	default:
		return "application/octet-stream"
	}
}

// checkContained verifies that path sits under one of the configured roots.
//
// This is belt-and-braces: the path is assembled from the index, which came
// from the scanner, so it should already be safe. Keeping the check means a
// future bug that lets a request influence a filename still cannot read
// outside the synced tree.
//
// When no roots are configured, containment cannot be evaluated; the check is
// skipped and startup warns about it.
func (s *Server) checkContained(path string) error {
	if !s.rootsConfigured || len(s.roots) == 0 {
		return nil
	}
	clean := filepath.Clean(path)
	for _, root := range s.roots {
		rootClean := filepath.Clean(root)
		if clean == rootClean {
			return nil
		}
		if strings.HasPrefix(clean, rootClean+string(os.PathSeparator)) {
			return nil
		}
	}
	return fmt.Errorf("httpapi: %s is outside every configured root", path)
}

// --- reindex ---------------------------------------------------------------

func (s *Server) handleReindex(w http.ResponseWriter, r *http.Request) {
	// Authorisation first: a remote caller should learn nothing about whether
	// reindexing is even wired up.
	if !isLoopback(r.RemoteAddr) {
		writeError(w, http.StatusForbidden, "forbidden", "reindex is limited to local callers")
		return
	}
	if s.reindex == nil {
		writeError(w, http.StatusNotImplemented, "unsupported", "reindex is not wired up")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Minute)
	defer cancel()

	idx, err := s.reindex(ctx)
	if err != nil {
		s.log.Error("reindex failed", "error", err)
		writeError(w, http.StatusInternalServerError, "internal", "reindex failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":    true,
		"index": idx.Stats(),
	})
}

func isLoopback(remoteAddr string) bool {
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		host = remoteAddr
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// --- error and JSON helpers ------------------------------------------------

type apiError struct {
	Error errorBody `json:"error"`
}

type errorBody struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	// Keep HTML-significant characters escaped; this is a JSON API and the
	// only way it reaches a browser is as data.
	enc.SetEscapeHTML(true)
	_ = enc.Encode(v)
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, apiError{Error: errorBody{Code: code, Message: message}})
}

// --- DTOs ------------------------------------------------------------------

// GalleryDTO is the list projection. It omits the page list on purpose: a
// thousand-gallery list with per-page detail would be megabytes of JSON for
// data the list never renders.
type GalleryDTO struct {
	GID            int64    `json:"gid"`
	Token          string   `json:"token,omitempty"`
	Title          string   `json:"title"`
	TitleJpn       string   `json:"title_jpn,omitempty"`
	TitleSource    string   `json:"title_source"`
	DirName        string   `json:"dir_name,omitempty"`
	Artists        []string `json:"artists,omitempty"`
	Groups         []string `json:"groups,omitempty"`
	Series         []string `json:"series,omitempty"`
	Events         []string `json:"events,omitempty"`
	Editions       []string `json:"editions,omitempty"`
	Category       int      `json:"category"`
	Posted         string   `json:"posted,omitempty"`
	Uploader       string   `json:"uploader,omitempty"`
	Rating         float64  `json:"rating"`
	SimpleLanguage string   `json:"simple_language,omitempty"`
	Label          string   `json:"label,omitempty"`
	State          int      `json:"state"`
	TimeMS         int64    `json:"download_time_ms"`
	PagesExpected  int      `json:"pages_expected"`
	PagesFound     int      `json:"pages_found"`
	TotalBytes     int64    `json:"total_bytes"`
	CoverURL       string   `json:"cover_url"`
	CoverKind      string   `json:"cover_kind"`
	Availability   string   `json:"availability"`
	Anomalies      []string `json:"anomalies"`
	MetaSource     string   `json:"meta_source"`
	OnDisk         bool     `json:"on_disk"`
}

type galleryListDTO struct {
	Items        []GalleryDTO `json:"items"`
	NextCursor   string       `json:"next_cursor"`
	Total        int          `json:"total"`
	Limit        int          `json:"limit"`
	IndexedAtMS  int64        `json:"indexed_at_ms"`
	SnapshotAtMS int64        `json:"snapshot_at_ms"`
}

// GalleryDetailDTO adds the page list and spider info.
type GalleryDetailDTO struct {
	GalleryDTO
	PagesDetail []pageDTO      `json:"pages_detail"`
	SpiderInfo  *spiderInfoDTO `json:"spider_info,omitempty"`
	PrevGID     int64          `json:"prev_gid,omitempty"`
	NextGID     int64          `json:"next_gid,omitempty"`
}

type pageDTO struct {
	Index    int    `json:"index"`
	Filename string `json:"filename"`
	Ext      string `json:"ext"`
	Size     int64  `json:"size"`
	MTimeMS  int64  `json:"mtime_ms"`
	URL      string `json:"url"`
}

type spiderInfoDTO struct {
	Version        int  `json:"version"`
	StartPage      int  `json:"start_page"`
	PreviewPages   int  `json:"preview_pages"`
	PreviewPerPage int  `json:"preview_per_page"`
	Pages          int  `json:"pages"`
	Present        bool `json:"present"`
}

// cleanTagParams normalises a repeated tag query parameter.
//
// Empty values are dropped so that "?artist=" — what an unchecked chip sends in
// some clients — cannot become a filter that matches nothing. Duplicates are
// removed so a cursor fingerprint does not depend on how many times a client
// repeated itself. Order is deliberately left alone: FilterFingerprint sorts,
// and sorting here as well would only hide a mistake in that function.
func cleanTagParams(values []string) []string {
	out := make([]string, 0, len(values))
	seen := map[string]bool{}
	for _, v := range values {
		v = strings.TrimSpace(v)
		if v == "" {
			continue
		}
		key := strings.ToLower(v)
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, v)
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

func toDTO(g *models.Gallery) GalleryDTO {
	anomalies := g.Anomalies
	if anomalies == nil {
		anomalies = []string{}
	}
	return GalleryDTO{
		GID:            g.GID,
		Token:          g.Token,
		Title:          g.Title,
		TitleJpn:       g.TitleJpn,
		TitleSource:    g.TitleSource,
		DirName:        g.DirName,
		Artists:        g.Artists,
		Groups:         g.Groups,
		Series:         g.Series,
		Events:         g.Events,
		Editions:       g.Editions,
		Category:       g.Category,
		Posted:         g.Posted,
		Uploader:       g.Uploader,
		Rating:         g.Rating,
		SimpleLanguage: g.SimpleLanguage,
		Label:          g.Label,
		State:          g.State,
		TimeMS:         g.TimeMS,
		PagesExpected:  g.PagesExpected,
		PagesFound:     g.PagesFound,
		TotalBytes:     g.TotalBytes,
		CoverURL:       g.CoverURL,
		CoverKind:      g.CoverKind,
		Availability:   string(g.Availability),
		Anomalies:      anomalies,
		MetaSource:     g.MetaSource,
		OnDisk:         g.OnDisk,
	}
}

func toDetailDTO(g *models.Gallery) GalleryDetailDTO {
	pages := make([]pageDTO, 0, len(g.Pages))
	for _, p := range g.Pages {
		pages = append(pages, pageDTO{
			Index:    p.Index,
			Filename: p.Filename,
			Ext:      p.Ext,
			Size:     p.Size,
			MTimeMS:  p.MTimeMS,
			URL:      p.URL,
		})
	}
	d := GalleryDetailDTO{
		GalleryDTO:  toDTO(g),
		PagesDetail: pages,
	}
	// Report the real .ehviewer header, or an explicit "absent". Never
	// synthesize preview counts: the client uses them to decide layout, and
	// invented values would silently produce the wrong reader.
	if g.Spider != nil {
		d.SpiderInfo = &spiderInfoDTO{
			Present:        true,
			Version:        g.Spider.Version,
			StartPage:      g.Spider.StartPage,
			PreviewPages:   g.Spider.PreviewPages,
			PreviewPerPage: g.Spider.PreviewPerPage,
			Pages:          g.Spider.Pages,
		}
	} else {
		d.SpiderInfo = &spiderInfoDTO{Present: false, Pages: g.PagesFound}
	}
	return d
}
