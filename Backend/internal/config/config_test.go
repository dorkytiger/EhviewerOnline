package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func writeFile(t *testing.T, name, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestLoadDefaults(t *testing.T) {
	cfg, err := Load("")
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Listen != "127.0.0.1:8080" {
		t.Errorf("listen: got %q, want the loopback default", cfg.Listen)
	}
	if cfg.Sync.DBPolicy != "latest" {
		t.Errorf("db_policy: got %q", cfg.Sync.DBPolicy)
	}
	if cfg.Sync.RescanInterval.Std() != 30*time.Minute {
		t.Errorf("rescan_interval: got %v", cfg.Sync.RescanInterval.Std())
	}
	if !cfg.Sync.SkipSymlinks {
		t.Error("skip_symlinks should default to true")
	}
	if cfg.Thumb.MaxDim != 480 || cfg.Thumb.Quality != 82 {
		t.Errorf("thumb defaults: %+v", cfg.Thumb)
	}
}

func TestLoadMissingFileIsNotAnError(t *testing.T) {
	// --root alone must be enough to start, so a named-but-absent config is
	// treated as "no config" rather than a failure.
	cfg, err := Load(filepath.Join(t.TempDir(), "nope.json"))
	if err != nil {
		t.Fatalf("expected no error for a missing file, got %v", err)
	}
	if cfg.Listen == "" {
		t.Error("defaults should still be applied")
	}
}

func TestLoadAcceptsCommentsAndBOM(t *testing.T) {
	// Both of these are things a real operator produces: a BOM from a Windows
	// editor or PowerShell's Set-Content, and // comments copied from the
	// sample config.
	src := "\ufeff{\n  // the bind address\n  \"listen\": \"127.0.0.1:9000\",\n" +
		"  \"sync\": { \"roots\": [\"/tmp/x\"] }\n}\n"
	cfg, err := Load(writeFile(t, "c.json", src))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Listen != "127.0.0.1:9000" {
		t.Errorf("listen: got %q", cfg.Listen)
	}
}

// A // inside a string literal must survive: a naive comment stripper would
// mangle it, and this config has plausible URL-ish values.
func TestStripCommentsKeepsStringContent(t *testing.T) {
	src := `{"proxy": {"client_ip_header": "X-Forwarded-For"}, "listen": "127.0.0.1:1" // note
}`
	out, err := stripComments(src)
	if err != nil {
		t.Fatalf("stripComments: %v", err)
	}
	if !strings.Contains(out, `"X-Forwarded-For"`) {
		t.Errorf("comment stripping corrupted a value: %s", out)
	}
	if strings.Contains(out, "// note") {
		t.Errorf("comment was not removed: %s", out)
	}

	// A URL value must not be truncated.
	urlSrc := `{"listen": "http://example.invalid:8080"}`
	out, err = stripComments(urlSrc)
	if err != nil {
		t.Fatal(err)
	}
	if out != urlSrc {
		t.Errorf("URL value was modified: %q -> %q", urlSrc, out)
	}
}

func TestStripCommentsRejectsUnterminatedString(t *testing.T) {
	if _, err := stripComments(`{"a": "unterminated}`); err == nil {
		t.Error("expected an error for an unterminated string")
	}
}

// A typo in a key name must be an error, not a silently-retained default.
func TestLoadRejectsUnknownKeys(t *testing.T) {
	_, err := Load(writeFile(t, "c.json", `{"listen_addr": "127.0.0.1:1"}`))
	if err == nil {
		t.Fatal("expected an error for an unknown key")
	}
	if !strings.Contains(err.Error(), "listen_addr") {
		t.Errorf("the error should name the offending key, got: %v", err)
	}
}

func TestDurationAcceptsStringAndNumber(t *testing.T) {
	path := writeFile(t, "c.json", `{"listen":"127.0.0.1:1","sync":{"rescan_interval":"15m","watch_debounce":5000000000}}`)
	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Sync.RescanInterval.Std() != 15*time.Minute {
		t.Errorf("rescan_interval: got %v", cfg.Sync.RescanInterval.Std())
	}
	if cfg.Sync.WatchDebounce.Std() != 5*time.Second {
		t.Errorf("watch_debounce: got %v", cfg.Sync.WatchDebounce.Std())
	}
}

func TestDurationRejectsGarbage(t *testing.T) {
	_, err := Load(writeFile(t, "c.json", `{"listen":"127.0.0.1:1","sync":{"rescan_interval":"soon"}}`))
	if err == nil {
		t.Fatal("expected an error for an unparseable duration")
	}
}

// ---------------------------------------------------------------------------
// Validate
// ---------------------------------------------------------------------------

func baseValid(t *testing.T) Config {
	t.Helper()
	cfg := Default()
	cfg.DataDir = filepath.Join(t.TempDir(), "state")
	return cfg
}

// The index and thumbnail cache must not land inside the synced tree, or
// Syncthing will sync them back to the phone and start fighting over them.
func TestValidateRejectsDataDirInsideSyncRoot(t *testing.T) {
	root := t.TempDir()
	cfg := baseValid(t)
	cfg.Sync.Roots = []string{root}
	cfg.DataDir = filepath.Join(root, "ehviewer-webd")

	err := cfg.Validate()
	if err == nil {
		t.Fatal("expected an error when data_dir is inside a sync root")
	}
	if !strings.Contains(err.Error(), "inside sync root") {
		t.Errorf("the error should explain the problem, got: %v", err)
	}
}

func TestValidateRejectsDataDirEqualToSyncRoot(t *testing.T) {
	root := t.TempDir()
	cfg := baseValid(t)
	cfg.Sync.Roots = []string{root}
	cfg.DataDir = root
	if err := cfg.Validate(); err == nil {
		t.Fatal("expected an error when data_dir equals a sync root")
	}
}

// The frp tunnel makes any non-loopback listener world-reachable, so serving
// unauthenticated on one is refused outright.
func TestValidateRejectsUnauthenticatedNonLoopback(t *testing.T) {
	cfg := baseValid(t)
	cfg.Sync.Roots = []string{t.TempDir()}
	cfg.Auth.Mode = "none"

	for _, listen := range []string{"0.0.0.0:8080", ":8080", "192.168.1.5:8080", "example.com:443"} {
		cfg.Listen = listen
		err := cfg.Validate()
		if err == nil {
			t.Errorf("listen %q: expected a refusal for auth.mode=none", listen)
			continue
		}
		if !strings.Contains(err.Error(), "auth.mode") {
			t.Errorf("listen %q: error should mention auth.mode, got: %v", listen, err)
		}
	}
}

func TestValidateAllowsUnauthenticatedOnLoopback(t *testing.T) {
	cfg := baseValid(t)
	cfg.Sync.Roots = []string{t.TempDir()}
	cfg.Auth.Mode = "none"
	for _, listen := range []string{"127.0.0.1:8080", "localhost:8080", "[::1]:8080"} {
		cfg.Listen = listen
		if err := cfg.Validate(); err != nil {
			t.Errorf("listen %q: expected no error, got %v", listen, err)
		}
	}
}

func TestValidateRequiresATokenInTokenMode(t *testing.T) {
	cfg := baseValid(t)
	cfg.Sync.Roots = []string{t.TempDir()}
	cfg.Auth.Mode = "token"
	cfg.Auth.Token = ""
	cfg.Auth.TokenFile = ""

	err := cfg.Validate()
	if err == nil {
		t.Fatal("expected an error when token mode has no token")
	}
	if !strings.Contains(err.Error(), "gentoken") {
		t.Errorf("the error should tell the operator how to make one, got: %v", err)
	}
}

func TestValidateRejectsUnknownModeAndPolicy(t *testing.T) {
	cfg := baseValid(t)
	cfg.Sync.Roots = []string{t.TempDir()}

	cfg.Auth.Mode = "password"
	if err := cfg.Validate(); err == nil {
		t.Error("expected an error for an unknown auth mode")
	}

	cfg.Auth.Mode = "token"
	cfg.Auth.Token = "t"
	cfg.Sync.DBPolicy = "freshest"
	if err := cfg.Validate(); err == nil {
		t.Error("expected an error for an unknown db_policy")
	}
}

// Secure cookies default on for a non-loopback listener (the tunnel is HTTPS),
// and off for loopback testing.
func TestValidateDefaultsSecureCookies(t *testing.T) {
	cfg := baseValid(t)
	cfg.Sync.Roots = []string{t.TempDir()}
	cfg.Auth.Token = "t"

	cfg.Listen = "127.0.0.1:8080"
	if err := cfg.Validate(); err != nil {
		t.Fatal(err)
	}
	if cfg.Auth.SecureCookies == nil || *cfg.Auth.SecureCookies {
		t.Error("secure_cookies should default to false on loopback")
	}

	cfg.Listen = "0.0.0.0:8080"
	cfg.Auth.SecureCookies = nil
	if err := cfg.Validate(); err != nil {
		t.Fatal(err)
	}
	if cfg.Auth.SecureCookies == nil || !*cfg.Auth.SecureCookies {
		t.Error("secure_cookies should default to true behind a proxy")
	}
}

func TestValidateNormalizesRootsToAbsolute(t *testing.T) {
	root := t.TempDir()
	cfg := baseValid(t)
	cfg.Sync.Roots = []string{root}
	cfg.Auth.Token = "t" // token mode requires a token to pass validation
	if err := cfg.Validate(); err != nil {
		t.Fatal(err)
	}
	if !filepath.IsAbs(cfg.Sync.Roots[0]) {
		t.Errorf("roots should be made absolute, got %q", cfg.Sync.Roots[0])
	}
}

// ---------------------------------------------------------------------------
// Path resolution
// ---------------------------------------------------------------------------

func TestResolveDownloadDirs(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "download"), 0o755); err != nil {
		t.Fatal(err)
	}

	cfg := Default()
	got := cfg.ResolveDownloadDirs(root)
	if len(got) != 1 || filepath.Base(got[0]) != "download" {
		t.Fatalf("got %v, want the download subdirectory", got)
	}
}

// When sync.roots points directly at the download directory — which is the
// natural thing to do if only that subtree is synced — it must still work.
func TestResolveDownloadDirsFallsBackToRoot(t *testing.T) {
	root := t.TempDir() // no "download" subdirectory
	cfg := Default()
	got := cfg.ResolveDownloadDirs(root)
	if len(got) != 1 || got[0] != root {
		t.Fatalf("got %v, want the root as a fallback", got)
	}
}

func TestResolveDBDir(t *testing.T) {
	root := t.TempDir()
	cfg := Default()
	if got := cfg.ResolveDBDir(root); got != "" {
		t.Errorf("got %q, want empty when there is no data subdirectory", got)
	}

	dataDir := filepath.Join(root, "data")
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if got := cfg.ResolveDBDir(root); got != dataDir {
		t.Errorf("got %q, want %q", got, dataDir)
	}
}

func TestTokenValue(t *testing.T) {
	cfg := Default()

	if tok, err := cfg.TokenValue(); err != nil || tok != "" {
		t.Errorf("no token configured should yield empty, got %q err=%v", tok, err)
	}

	cfg.Auth.TokenFile = writeFile(t, "token", "  from-file \n")
	tok, err := cfg.TokenValue()
	if err != nil {
		t.Fatalf("TokenValue: %v", err)
	}
	if tok != "from-file" {
		t.Errorf("got %q, want the trimmed file contents", tok)
	}

	// An inline token wins over the file.
	cfg.Auth.Token = "inline"
	tok, err = cfg.TokenValue()
	if err != nil {
		t.Fatal(err)
	}
	if tok != "inline" {
		t.Errorf("got %q, want the inline token", tok)
	}
}

func TestTokenValueRejectsEmptyFile(t *testing.T) {
	cfg := Default()
	cfg.Auth.TokenFile = writeFile(t, "token", "   \n")
	if _, err := cfg.TokenValue(); err == nil {
		t.Error("expected an error for an empty token file")
	}
}

// The shipped sample must actually load: it is the first thing an operator
// copies.
func TestSampleConfigIsLoadable(t *testing.T) {
	sample := Sample()
	if !strings.Contains(sample, "//") {
		t.Fatal("the sample should carry comments to be useful")
	}
	cfg, err := Load(writeFile(t, "sample.json", sample))
	if err != nil {
		t.Fatalf("the sample config does not load: %v", err)
	}
	if cfg.Sync.DBPolicy != "latest" {
		t.Errorf("sample db_policy: got %q", cfg.Sync.DBPolicy)
	}
	if len(cfg.Sync.Roots) == 0 {
		t.Error("the sample should show a roots entry")
	}
	// It points at /srv, which does not exist here, so validation is expected
	// to pass structurally (roots are only required to be non-empty).
	if err := cfg.Validate(); err != nil {
		t.Fatalf("the sample config does not validate: %v", err)
	}
}
