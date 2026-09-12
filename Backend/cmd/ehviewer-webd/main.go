// Command ehviewer-webd serves a read-only web view of an EhViewer library
// that has been synced to this machine.
//
// It never writes to the synced tree. The only things it creates are its own
// index, thumbnail cache and session key, all under data_dir, which the config
// validator refuses to place inside a sync root.
//
// Subcommands:
//
//	ehviewer-webd serve                 run the service (default)
//	ehviewer-webd gentoken              print a fresh access token
//	ehviewer-webd sampleconfig          print an annotated example config
//	ehviewer-webd scan [--root DIR]     scan once and print a summary
//
// The scan subcommand exists because the first useful thing to do with a new
// deployment is confirm that the directory layout is what the scanner expects;
// see the design doc §11 for the questions it answers.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/warren/ehviewer-webd/internal/auth"
	"github.com/warren/ehviewer-webd/internal/builder"
	"github.com/warren/ehviewer-webd/internal/config"
	"github.com/warren/ehviewer-webd/internal/events"
	"github.com/warren/ehviewer-webd/internal/httpapi"
	"github.com/warren/ehviewer-webd/internal/index"
	"github.com/warren/ehviewer-webd/internal/scan"
	"github.com/warren/ehviewer-webd/internal/thumbcache"
	"github.com/warren/ehviewer-webd/internal/watch"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "error: "+err.Error())
		os.Exit(1)
	}
}

func run(args []string) error {
	cmd := "serve"
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		cmd = args[0]
		args = args[1:]
	}
	switch cmd {
	case "serve":
		return cmdServe(args)
	case "gentoken":
		return cmdGenToken(args)
	case "sampleconfig":
		fmt.Print(config.Sample())
		return nil
	case "scan":
		return cmdScan(args)
	case "version":
		fmt.Println(httpapi.Version)
		return nil
	case "help", "-h", "--help":
		usage()
		return nil
	default:
		usage()
		return fmt.Errorf("unknown command %q", cmd)
	}
}

func usage() {
	fmt.Fprint(os.Stderr, `ehviewer-webd - read-only web view of a synced EhViewer library

usage:
  ehviewer-webd serve       [-config FILE] [-root DIR] [-listen ADDR] [-data-dir DIR] [-log-level LVL]
  ehviewer-webd scan        [-config FILE] [-root DIR] [-json]
  ehviewer-webd gentoken    [-bytes N]
  ehviewer-webd sampleconfig
  ehviewer-webd version

flags for serve/scan:
  -config     path to a JSON config file (optional)
  -root       synced EhViewer directory; overrides sync.roots
  -listen     bind address; overrides listen
  -data-dir   writable state directory; overrides data_dir
  -log-level  debug | info | warn | error
`)
}

// sharedFlags holds the flags both serve and scan accept.
type sharedFlags struct {
	configPath string
	root       string
	listen     string
	dataDir    string
	logLevel   string
}

func registerShared(fs *flag.FlagSet, sf *sharedFlags) {
	fs.StringVar(&sf.configPath, "config", "", "path to a JSON config file")
	fs.StringVar(&sf.root, "root", "", "synced EhViewer directory (overrides sync.roots)")
	fs.StringVar(&sf.listen, "listen", "", "bind address (overrides listen)")
	fs.StringVar(&sf.dataDir, "data-dir", "", "writable state directory (overrides data_dir)")
	fs.StringVar(&sf.logLevel, "log-level", "", "debug | info | warn | error")
}

// loadConfig applies file then flag precedence and validates the result.
func loadConfig(sf sharedFlags) (config.Config, error) {
	cfg, err := config.Load(sf.configPath)
	if err != nil {
		return cfg, err
	}
	if sf.root != "" {
		cfg.Sync.Roots = []string{sf.root}
	}
	if len(cfg.Sync.Roots) == 0 {
		return cfg, errors.New(
			"no sync root configured: pass -root DIR or set sync.roots in the config file")
	}
	if sf.listen != "" {
		cfg.Listen = sf.listen
	}
	if sf.dataDir != "" {
		cfg.DataDir = sf.dataDir
	}
	if sf.logLevel != "" {
		cfg.Logging.Level = sf.logLevel
	}
	if err := cfg.Validate(); err != nil {
		return cfg, err
	}
	return cfg, nil
}

func newLogger(cfg config.Config) *slog.Logger {
	var level slog.Level
	switch strings.ToLower(cfg.Logging.Level) {
	case "debug":
		level = slog.LevelDebug
	case "warn", "warning":
		level = slog.LevelWarn
	case "error":
		level = slog.LevelError
	default:
		level = slog.LevelInfo
	}
	opts := &slog.HandlerOptions{Level: level}
	var h slog.Handler
	if strings.EqualFold(cfg.Logging.Format, "json") {
		h = slog.NewJSONHandler(os.Stdout, opts)
	} else {
		h = slog.NewTextHandler(os.Stdout, opts)
	}
	return slog.New(h)
}

// --- serve -----------------------------------------------------------------

func cmdServe(args []string) error {
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	var sf sharedFlags
	registerShared(fs, &sf)
	if err := fs.Parse(args); err != nil {
		return err
	}

	cfg, err := loadConfig(sf)
	if err != nil {
		return err
	}
	log := newLogger(cfg)
	slog.SetDefault(log)

	if err := builder.EnsureDataDir(cfg); err != nil {
		return err
	}

	token, err := cfg.TokenValue()
	if err != nil {
		return err
	}
	authMgr, err := auth.New(auth.Options{
		Mode:          auth.Mode(cfg.Auth.Mode),
		Token:         token,
		KeyPath:       cfg.SessionKeyPath(),
		CookieName:    cfg.Auth.CookieName,
		TTL:           cfg.Auth.SessionTTL.Std(),
		SecureCookies: cfg.Auth.SecureCookies != nil && *cfg.Auth.SecureCookies,
	})
	if err != nil {
		return err
	}

	// Initial build. A failure here is fatal only if the index cannot be built
	// at all; the error text is meant to be actionable.
	//
	// The hub exists before the first build so a client that connects during
	// startup still receives the first change notification.
	hub := events.NewHub()
	b := builder.NewWithPublisher(cfg, index.NewStore(nil), log, &hubPublisher{hub: hub})
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	idx, err := b.RebuildFor(ctx, builder.ReasonStartup)
	if err != nil {
		return err
	}
	if idx == nil {
		return errors.New("index build produced no result")
	}

	roots, rootsConfigured := cfg.RootForContainment()
	if !rootsConfigured {
		log.Warn("no sync.roots configured; the image path containment check is disabled")
	}

	var thumbs *thumbcache.Cache
	if cfg.Thumb.Enabled {
		thumbs, err = thumbcache.New(thumbcache.Options{
			Dir:     cfg.ThumbDir(),
			MaxDim:  cfg.Thumb.MaxDim,
			Quality: cfg.Thumb.Quality,
			Workers: cfg.Thumb.Workers,
		})
		if err != nil {
			// Covers degrade to originals rather than the service failing.
			log.Warn("thumbnail cache unavailable; covers will be served at full size",
				"error", err)
			thumbs = nil
		}
	}

	srv, err := httpapi.New(httpapi.Options{
		Store:           b.Store(),
		Auth:            authMgr,
		Thumbs:          thumbs,
		Logger:          log,
		Roots:           roots,
		RootsConfigured: rootsConfigured,
		Reindex:         b.Rebuild,
		Events:          hub,
	})
	if err != nil {
		return err
	}
	defer hub.Close()

	// Watch for changes and for the fallback rescan.
	var watcher *watch.Watcher
	if cfg.Sync.Watch {
		watcher, err = watch.New(watch.Options{
			Roots:    b.WatchRoots(),
			DBDirs:   b.WatchDBDirs(),
			Debounce: cfg.Sync.WatchDebounce.Std(),
			MaxDelay: 30 * time.Second,
			OnChange: func(ctx context.Context, dbChanged bool) {
				_, _ = b.RebuildFor(ctx, builder.ReasonWatch)
			},
			Logger: log,
		})
		if err != nil {
			log.Warn("filesystem watching unavailable; falling back to periodic rescans",
				"error", err)
			watcher = nil
		} else {
			defer watcher.Close()
		}
	}
	go periodicRescan(ctx, b, log)

	httpServer := &http.Server{
		Addr:              cfg.Listen,
		Handler:           srv.Handler(),
		ReadHeaderTimeout: cfg.Limits.ReadHeaderTimeout.Std(),
		ReadTimeout:       cfg.Limits.ReadTimeout.Std(),
		// WriteTimeout is deliberately not set from config.
		//
		// One global write deadline cannot serve both cases this server has: a
		// page image may legitimately take minutes over a tunnel, while an SSE
		// stream must stay open for as long as the client wants it. Go applies
		// WriteTimeout to the whole connection, so any non-zero value here
		// eventually kills every event stream. Handlers bound themselves
		// instead: the image handler and the SSE handler both set a per-write
		// deadline via http.ResponseController.
		WriteTimeout: 0,
		IdleTimeout:  cfg.Limits.IdleTimeout.Std(),
	}

	errCh := make(chan error, 1)
	go func() {
		log.Info("listening",
			"addr", cfg.Listen,
			"auth_mode", cfg.Auth.Mode,
			"galleries", idx.Len(),
			"watch", watcher != nil,
		)
		if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
		log.Info("shutting down")
		shutdownCtx, cancelShutdown := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancelShutdown()
		return httpServer.Shutdown(shutdownCtx)
	}
}

// hubPublisher adapts the events hub to builder.Publisher.
//
// The adapter exists so the builder does not import the events package: the
// builder's job is to produce an index, and its notion of "someone wants to
// know" is one method wide.
type hubPublisher struct {
	hub *events.Hub
}

func (p *hubPublisher) Broadcast(e builder.Event) {
	p.hub.Broadcast(events.Event{
		Name:         events.EventIndexChanged,
		IndexAtMS:    e.IndexAtMS,
		SnapshotAtMS: e.SnapshotAtMS,
		Galleries:    e.Galleries,
		Added:        e.Added,
		Changed:      e.Changed,
		Removed:      e.Removed,
		Truncated:    e.Truncated,
		Reason:       e.Reason,
	})
}

func (p *hubPublisher) Subscribers() int { return p.hub.Subscribers() }

// periodicRescan is the safety net for lost filesystem events. inotify can
// drop events (queue overflow, a watch on a directory that was replaced), so a
// slow full verification runs regardless of whether the watcher is active.
func periodicRescan(ctx context.Context, b *builder.Builder, log *slog.Logger) {
	interval := b.RescanInterval()
	if interval <= 0 {
		return
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			log.Debug("periodic rescan")
			if _, err := b.RebuildFor(ctx, builder.ReasonPeriodic); err != nil {
				log.Warn("periodic rescan failed", "error", err)
			}
		}
	}
}

// --- gentoken --------------------------------------------------------------

func cmdGenToken(args []string) error {
	fs := flag.NewFlagSet("gentoken", flag.ContinueOnError)
	bytes := fs.Int("bytes", 32, "entropy in bytes")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *bytes < 16 {
		return errors.New("refusing to generate a token shorter than 16 bytes")
	}
	tok, err := auth.GenerateToken(*bytes)
	if err != nil {
		return err
	}
	fmt.Println(tok)
	return nil
}

// --- scan ------------------------------------------------------------------

// scanReport is the reconnaissance output described in the design doc §11. Its
// job is to answer, before anything is deployed, the questions that determine
// whether the rest of the design holds:
//
//   - do directory names all match <gid>-<title>, and how many do not?
//   - do v1 .ehviewer files exist in the wild?
//   - how large is the biggest gallery, and is the tree unusually uneven?
//   - what are the real category values (the CATEGORY enum cannot be verified
//     from source, because EhUtils lives in an AAR dependency)?
//   - what share of galleries have no usable metadata at all?
type scanReport struct {
	Roots         []string       `json:"roots"`
	DownloadDirs  []string       `json:"download_dirs"`
	ScannedAtMS   int64          `json:"scanned_at_ms"`
	DirCount      int            `json:"dir_count"`
	Galleries     int            `json:"galleries"`
	Pages         int            `json:"pages"`
	TotalBytes    int64          `json:"total_bytes"`
	MaxPagesOne   int            `json:"max_pages_in_one_gallery"`
	MeanPages     float64        `json:"mean_pages_per_gallery"`
	V1SpiderFiles int            `json:"v1_spiderinfo_files"`
	V2SpiderFiles int            `json:"v2_spiderinfo_files"`
	BadSpiderInfo int            `json:"invalid_or_missing_spiderinfo_files"`
	Availability  map[string]int `json:"availability"`
	Anomalies     map[string]int `json:"anomalies"`
	TitleSources  map[string]int `json:"title_sources"`
	MetaSources   map[string]int `json:"meta_sources"`
	Languages     map[string]int `json:"languages"`
	Categories    map[string]int `json:"categories"`
	PageExtension map[string]int `json:"first_page_extension"`
	Skipped       []scan.Skip    `json:"skipped,omitempty"`
	Warnings      []string       `json:"warnings,omitempty"`
}

// cmdScan performs a single scan and prints a summary. This is the
// reconnaissance step from the design doc §11: it answers whether the layout is
// what the scanner expects before anything is deployed.
func cmdScan(args []string) error {
	fs := flag.NewFlagSet("scan", flag.ContinueOnError)
	var sf sharedFlags
	registerShared(fs, &sf)
	asJSON := fs.Bool("json", false, "print the report as JSON")
	if err := fs.Parse(args); err != nil {
		return err
	}

	cfg, err := loadConfig(sf)
	if err != nil {
		return err
	}
	log := newLogger(cfg)

	b := builder.New(cfg, index.NewStore(nil), log)

	// Build a real index so the report reflects exactly what the service would
	// serve, including the DB snapshot merge. Keeping a separate scan-only path
	// here would risk the report disagreeing with reality.
	idx, err := b.Rebuild(context.Background())
	if err != nil {
		return err
	}

	report := scanReport{
		Roots:         cfg.Sync.Roots,
		DownloadDirs:  b.WatchRoots(),
		ScannedAtMS:   time.Now().UnixMilli(),
		Galleries:     idx.Len(),
		Availability:  map[string]int{},
		Anomalies:     map[string]int{},
		TitleSources:  map[string]int{},
		MetaSources:   map[string]int{},
		Languages:     map[string]int{},
		Categories:    map[string]int{},
		PageExtension: map[string]int{},
	}
	for _, s := range idx.Skipped() {
		report.Skipped = append(report.Skipped, s)
	}
	report.DirCount = len(idx.Skipped()) + idx.Stats().OnDisk
	report.Warnings = append(report.Warnings, idx.Warnings()...)

	for _, g := range idx.All() {
		report.Pages += g.PagesFound
		report.TotalBytes += g.TotalBytes
		if g.PagesFound > report.MaxPagesOne {
			report.MaxPagesOne = g.PagesFound
		}
		for _, a := range g.Anomalies {
			report.Anomalies[a]++
		}
		report.Availability[string(g.Availability)]++
		report.TitleSources[g.TitleSource]++
		report.MetaSources[g.MetaSource]++
		report.Languages[orNone(g.SimpleLanguage)]++
		report.Categories[strconv.Itoa(g.Category)]++

		switch {
		case g.Spider == nil:
			report.BadSpiderInfo++
		case g.Spider.Version == 1:
			report.V1SpiderFiles++
		default:
			report.V2SpiderFiles++
		}
		if len(g.Pages) > 0 {
			report.PageExtension[g.Pages[0].Ext]++
		}
	}
	if report.Galleries > 0 {
		report.MeanPages = float64(report.Pages) / float64(report.Galleries)
	}

	if *asJSON {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		return enc.Encode(report)
	}
	printReport(report)
	return nil
}

func printReport(r scanReport) {
	fmt.Printf("roots:            %s\n", strings.Join(r.Roots, ", "))
	fmt.Printf("download dirs:    %s\n", strings.Join(r.DownloadDirs, ", "))
	fmt.Printf("directories:      %d\n", r.DirCount)
	fmt.Printf("galleries:        %d\n", r.Galleries)
	fmt.Printf("pages:            %d\n", r.Pages)
	fmt.Printf("bytes:            %d (%.2f GiB)\n", r.TotalBytes, float64(r.TotalBytes)/(1<<30))
	fmt.Printf("pages/gallery:    mean %.1f, max %d\n", r.MeanPages, r.MaxPagesOne)
	fmt.Printf(".ehviewer:        v1=%d v2=%d missing-or-invalid=%d\n",
		r.V1SpiderFiles, r.V2SpiderFiles, r.BadSpiderInfo)
	fmt.Printf("availability:     %s\n", formatCounts(r.Availability))
	fmt.Printf("meta sources:     %s\n", formatCounts(r.MetaSources))
	fmt.Printf("title sources:    %s\n", formatCounts(r.TitleSources))
	fmt.Printf("languages:        %s\n", formatCounts(r.Languages))
	fmt.Printf("categories:       %s\n", formatCounts(r.Categories))
	fmt.Printf("first-page ext:   %s\n", formatCounts(r.PageExtension))
	if len(r.Anomalies) == 0 {
		fmt.Printf("anomalies:        (none)\n")
	} else {
		fmt.Printf("anomalies:        %s\n", formatCounts(r.Anomalies))
	}

	if len(r.Skipped) > 0 {
		fmt.Printf("\nskipped directories (%d):\n", len(r.Skipped))
		limit := len(r.Skipped)
		if limit > 20 {
			limit = 20
		}
		for _, s := range r.Skipped[:limit] {
			fmt.Printf("  - %s: %s\n", s.Path, s.Reason)
		}
		if len(r.Skipped) > limit {
			fmt.Printf("  ... and %d more\n", len(r.Skipped)-limit)
		}
	}
	if len(r.Warnings) > 0 {
		fmt.Printf("\nwarnings:\n")
		for _, w := range r.Warnings {
			fmt.Printf("  - %s\n", w)
		}
	}
}

func formatCounts(m map[string]int) string {
	if len(m) == 0 {
		return "(none)"
	}
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		if m[keys[i]] != m[keys[j]] {
			return m[keys[i]] > m[keys[j]]
		}
		return keys[i] < keys[j]
	})
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, fmt.Sprintf("%s=%d", k, m[k]))
	}
	return strings.Join(parts, " ")
}

func orNone(s string) string {
	if s == "" {
		return "(none)"
	}
	return s
}
