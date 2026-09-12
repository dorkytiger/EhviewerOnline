// Package config loads the service configuration.
//
// The format is JSON rather than TOML or YAML so that the service has no
// config-parsing dependency at all. A JSON config also rejects malformed input
// loudly, which matters because a silently-defaulted path here means indexing
// the wrong directory.
//
// Every field is optional; defaults are applied by Default() and then
// overridden by the file, then by environment variables, then by flags. The
// precedence is deliberate: flags win, because that is what a person typing a
// command expects.
package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/warren/ehviewer-webd/internal/auth"
	"github.com/warren/ehviewer-webd/internal/dbexport"
)

// Config is the whole configuration.
type Config struct {
	// Listen is the address the HTTP server binds. Defaults to loopback so a
	// misconfiguration cannot expose the service directly.
	Listen string `json:"listen"`
	// DataDir holds the index, thumbnail cache and session key. It must not
	// live inside any sync root.
	DataDir string `json:"data_dir"`

	Sync    SyncConfig    `json:"sync"`
	Auth    AuthConfig    `json:"auth"`
	Proxy   ProxyConfig   `json:"proxy"`
	Limits  LimitsConfig  `json:"limits"`
	Thumb   ThumbConfig   `json:"thumb"`
	Logging LoggingConfig `json:"logging"`

	// ConfigPath records where this was loaded from, for diagnostics.
	ConfigPath string `json:"-"`
}

// SyncConfig describes the synced EhViewer tree.
type SyncConfig struct {
	// Roots are the top-level directories that were synced. Used for the path
	// containment check.
	Roots []string `json:"roots"`
	// DownloadDirs are candidate gallery directories, relative to each root
	// unless absolute. Defaults to ["download"].
	//
	// This cannot be hardcoded to "download": Settings.getDownloadLocation()
	// returns a UniFile the user may have pointed anywhere, so the operator
	// needs a way to name the real directory.
	DownloadDirs []string `json:"download_dirs"`
	// DBDirs are candidate snapshot directories. Defaults to ["data"].
	DBDirs []string `json:"db_dirs"`
	// DBPolicy is "latest" or "merge". Defaults to "latest".
	DBPolicy string `json:"db_policy"`
	// RescanInterval is the fallback full-verification period. Defaults to 30m.
	RescanInterval Duration `json:"rescan_interval"`
	// Watch enables fsnotify-based incremental updates.
	Watch bool `json:"watch"`
	// WatchDebounce is how long to coalesce filesystem events. Defaults to 2s.
	WatchDebounce Duration `json:"watch_debounce"`
	// SkipSymlinks refuses to index symlinked gallery directories.
	SkipSymlinks bool `json:"skip_symlinks"`
	// Workers bounds concurrent directory reads. Zero means "pick from CPU".
	Workers int `json:"workers"`
	// MaxPages caps the page count accepted from .ehviewer.
	MaxPages int `json:"max_pages"`
	// MaxGalleries refuses to build an index larger than this. Guards against
	// pointing the service at the wrong directory by accident.
	MaxGalleries int `json:"max_galleries"`
}

// AuthConfig controls access.
type AuthConfig struct {
	// Mode is "none" or "token". "none" is only accepted with a loopback
	// listener.
	Mode string `json:"mode"`
	// TokenFile is a file containing the shared token. The file is read at
	// startup and never logged.
	TokenFile string `json:"token_file"`
	// Token is the shared secret inline. Prefer TokenFile so the secret does
	// not end up in a config file that might be committed.
	Token string `json:"token"`
	// CookieName defaults to "ehw_session".
	CookieName string `json:"cookie_name"`
	// SessionTTL defaults to 720h (30 days).
	SessionTTL Duration `json:"session_ttl"`
	// SecureCookies marks the session cookie Secure. Defaults to true; only
	// set false for plain-HTTP loopback testing.
	SecureCookies *bool `json:"secure_cookies"`
}

// ProxyConfig describes the reverse proxy in front of this service.
type ProxyConfig struct {
	// TrustedProxies lists CIDRs whose X-Forwarded-For is believed. Behind
	// frp this must include the frpc address, or every request looks like it
	// came from the proxy and one abusive client throttles everyone
	// (design doc F4).
	TrustedProxies []string `json:"trusted_proxies"`
	// ClientIPHeader defaults to X-Forwarded-For.
	ClientIPHeader string `json:"client_ip_header"`
}

// LimitsConfig bounds resource use.
type LimitsConfig struct {
	// ReadHeaderTimeout, ReadTimeout and WriteTimeout are HTTP server
	// timeouts. WriteTimeout must stay generous (or 0) because image bodies
	// travel over a tunnel.
	ReadHeaderTimeout Duration `json:"read_header_timeout"`
	ReadTimeout       Duration `json:"read_timeout"`
	WriteTimeout      Duration `json:"write_timeout"`
	IdleTimeout       Duration `json:"idle_timeout"`
	// MaxGlobalConcurrency caps simultaneous in-flight requests.
	MaxGlobalConcurrency int `json:"max_global_concurrency"`
	// RateLimitPerMinute caps requests per client IP per minute. 0 disables.
	RateLimitPerMinute int `json:"rate_limit_per_minute"`
	// LoginRateLimitPerMinute is the tighter budget for the login endpoint.
	LoginRateLimitPerMinute int `json:"login_rate_limit_per_minute"`
}

// ThumbConfig controls thumbnail rendering.
type ThumbConfig struct {
	Enabled bool `json:"enabled"`
	// MaxDim is the long edge of a rendered thumbnail. Defaults to 480.
	MaxDim int `json:"max_dim"`
	// Quality is the JPEG quality. Defaults to 82.
	Quality int `json:"quality"`
	// Workers caps concurrent renders. Defaults to 2.
	Workers int `json:"workers"`
}

// LoggingConfig controls logging.
type LoggingConfig struct {
	// Level is debug, info, warn or error.
	Level string `json:"level"`
	// Format is "text" or "json".
	Format string `json:"format"`
}

// Default returns the baseline configuration.
func Default() Config {
	return Config{
		Listen:  "127.0.0.1:8080",
		DataDir: defaultDataDir(),
		Sync: SyncConfig{
			Roots:          nil,
			DownloadDirs:   []string{"download"},
			DBDirs:         []string{"data"},
			DBPolicy:       string(dbexport.PolicyLatest),
			RescanInterval: Duration(30 * time.Minute),
			Watch:          true,
			WatchDebounce:  Duration(2 * time.Second),
			SkipSymlinks:   true,
			MaxPages:       100_000,
			MaxGalleries:   500_000,
		},
		Auth: AuthConfig{
			Mode:       string(auth.ModeToken),
			CookieName: "ehw_session",
			SessionTTL: Duration(30 * 24 * time.Hour),
		},
		Proxy: ProxyConfig{
			ClientIPHeader: "X-Forwarded-For",
		},
		Limits: LimitsConfig{
			ReadHeaderTimeout:       Duration(10 * time.Second),
			ReadTimeout:             Duration(60 * time.Second),
			WriteTimeout:            Duration(5 * time.Minute),
			IdleTimeout:             Duration(120 * time.Second),
			MaxGlobalConcurrency:    64,
			RateLimitPerMinute:      600,
			LoginRateLimitPerMinute: 10,
		},
		Thumb: ThumbConfig{
			Enabled: true,
			MaxDim:  480,
			Quality: 82,
			Workers: 2,
		},
		Logging: LoggingConfig{
			Level:  "info",
			Format: "text",
		},
	}
}

func defaultDataDir() string {
	if dir, err := os.UserConfigDir(); err == nil && dir != "" {
		return filepath.Join(dir, "ehviewer-webd")
	}
	return "ehviewer-webd-data"
}

// Duration wraps time.Duration so it can be written as a string in JSON
// ("30m", "2s") while still accepting a plain nanosecond number.
type Duration time.Duration

// UnmarshalJSON accepts both "30m" and 1800000000000.
func (d *Duration) UnmarshalJSON(b []byte) error {
	s := strings.TrimSpace(string(b))
	if s == "null" {
		return nil
	}
	if len(s) > 0 && s[0] == '"' {
		var str string
		if err := json.Unmarshal(b, &str); err != nil {
			return err
		}
		parsed, err := time.ParseDuration(str)
		if err != nil {
			return fmt.Errorf("config: bad duration %q: %w", str, err)
		}
		*d = Duration(parsed)
		return nil
	}
	var n int64
	if err := json.Unmarshal(b, &n); err != nil {
		return fmt.Errorf("config: bad duration %s: %w", string(b), err)
	}
	*d = Duration(time.Duration(n))
	return nil
}

// MarshalJSON renders the duration as a string.
func (d Duration) MarshalJSON() ([]byte, error) {
	return json.Marshal(time.Duration(d).String())
}

// Std returns the standard library duration.
func (d Duration) Std() time.Duration { return time.Duration(d) }

// Load reads a config file over the defaults. An empty path and a missing file
// both yield the defaults with no error, so the service can start with nothing
// but a --root flag.
func Load(path string) (Config, error) {
	cfg := Default()
	if path == "" {
		return cfg, nil
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return cfg, nil
		}
		return cfg, fmt.Errorf("config: read %q: %w", path, err)
	}

	// A UTF-8 BOM is common when a file is written by a Windows editor or by
	// PowerShell's Set-Content. encoding/json rejects it with a confusing
	// "invalid character '\ufeff'" message, so strip it here.
	src := strings.TrimPrefix(string(raw), "\ufeff")

	// The sample config ships with // comments. Standard JSON has none, so
	// strip them here rather than forcing operators to keep a bare file.
	cleaned, err := stripComments(src)
	if err != nil {
		return cfg, fmt.Errorf("config: %q: %w", path, err)
	}

	dec := json.NewDecoder(strings.NewReader(cleaned))
	// Reject unknown keys: a typo like "listen_addr" would otherwise silently
	// leave the default in place, which is how a service ends up listening
	// somewhere the operator did not intend.
	dec.DisallowUnknownFields()
	if err := dec.Decode(&cfg); err != nil {
		return cfg, fmt.Errorf("config: parse %q: %w", path, err)
	}
	cfg.ConfigPath = path
	return cfg, nil
}

// stripComments removes // line comments that are not inside a string literal.
//
// A naive "cut at //" would corrupt any value containing a URL, and this
// config has several plausible ones (a proxy host, a doc link). Tracking
// string state is a few lines and removes the whole class of surprise.
func stripComments(src string) (string, error) {
	var b strings.Builder
	b.Grow(len(src))

	inString := false
	escaped := false

	for i := 0; i < len(src); i++ {
		c := src[i]

		if inString {
			b.WriteByte(c)
			switch {
			case escaped:
				escaped = false
			case c == '\\':
				escaped = true
			case c == '"':
				inString = false
			}
			continue
		}

		if c == '"' {
			inString = true
			b.WriteByte(c)
			continue
		}
		if c == '/' && i+1 < len(src) && src[i+1] == '/' {
			// Skip to end of line, but keep the newline so line numbers in
			// JSON errors still match the file.
			for i < len(src) && src[i] != '\n' {
				i++
			}
			if i < len(src) {
				b.WriteByte('\n')
			}
			continue
		}
		b.WriteByte(c)
	}

	if inString {
		return "", errors.New("unterminated string literal")
	}
	return b.String(), nil
}

// Validate checks invariants and fills derived values. It returns an error
// rather than repairing anything silently.
func (c *Config) Validate() error {
	if c.Listen == "" {
		return errors.New("config: listen must not be empty")
	}
	if c.DataDir == "" {
		return errors.New("config: data_dir must not be empty")
	}

	// The data directory must live outside every sync root, or the index and
	// thumbnail cache get synced back to the phone and Syncthing starts
	// fighting over them.
	dataAbs, err := filepath.Abs(c.DataDir)
	if err != nil {
		return fmt.Errorf("config: data_dir: %w", err)
	}
	for i, root := range c.Sync.Roots {
		if root == "" {
			return fmt.Errorf("config: sync.roots[%d] is empty", i)
		}
		rootAbs, err := filepath.Abs(root)
		if err != nil {
			return fmt.Errorf("config: sync.roots[%d]: %w", i, err)
		}
		c.Sync.Roots[i] = rootAbs
		if isWithin(dataAbs, rootAbs) {
			return fmt.Errorf(
				"config: data_dir %q is inside sync root %q; the index and thumbnail "+
					"cache would be synced back to the phone. Choose a path outside the "+
					"synced tree", c.DataDir, root)
		}
	}

	switch auth.Mode(c.Auth.Mode) {
	case auth.ModeNone:
		if !isLoopbackListen(c.Listen) {
			return fmt.Errorf(
				"config: auth.mode is %q but listen is %q; refusing to serve the "+
					"library unauthenticated on a non-loopback address (the frp tunnel "+
					"makes it world-reachable)", c.Auth.Mode, c.Listen)
		}
	case auth.ModeToken:
		if c.Auth.Token == "" && c.Auth.TokenFile == "" {
			return errors.New(
				"config: auth.mode is \"token\" but neither auth.token nor " +
					"auth.token_file is set; generate one with `ehviewer-webd gentoken`")
		}
	default:
		return fmt.Errorf("config: unknown auth.mode %q", c.Auth.Mode)
	}

	if _, ok := dbexport.ParseMergePolicy(c.Sync.DBPolicy); !ok {
		return fmt.Errorf("config: sync.db_policy must be \"latest\" or \"merge\", got %q",
			c.Sync.DBPolicy)
	}

	if len(c.Sync.DownloadDirs) == 0 {
		c.Sync.DownloadDirs = []string{"download"}
	}
	if len(c.Sync.DBDirs) == 0 {
		c.Sync.DBDirs = []string{"data"}
	}

	if c.Auth.SecureCookies == nil {
		// Default on. The tunnel is HTTPS, and a non-Secure cookie over HTTPS
		// is a needless downgrade.
		v := !isLoopbackListen(c.Listen)
		c.Auth.SecureCookies = &v
	}

	if c.Limits.MaxGlobalConcurrency <= 0 {
		c.Limits.MaxGlobalConcurrency = 64
	}
	if c.Thumb.MaxDim <= 0 {
		c.Thumb.MaxDim = 480
	}
	if c.Thumb.Quality <= 0 {
		c.Thumb.Quality = 82
	}
	if c.Thumb.Workers <= 0 {
		c.Thumb.Workers = 2
	}
	if c.Sync.MaxPages <= 0 {
		c.Sync.MaxPages = 100_000
	}
	if c.Sync.MaxGalleries <= 0 {
		c.Sync.MaxGalleries = 500_000
	}
	if c.Logging.Level == "" {
		c.Logging.Level = "info"
	}
	if c.Logging.Format == "" {
		c.Logging.Format = "text"
	}
	return nil
}

// ResolveDownloadDirs returns the existing candidate gallery directories for a
// root, preferring the configured list and falling back to the root itself.
//
// Returning the root as a fallback means an operator can point sync.roots at
// the download directory directly instead of at the EhViewer directory, which
// is the natural thing to do when only that subtree is synced.
func (c *Config) ResolveDownloadDirs(root string) []string {
	var out []string
	seen := map[string]bool{}
	add := func(p string) {
		if p == "" || seen[p] {
			return
		}
		seen[p] = true
		out = append(out, p)
	}
	for _, cand := range c.Sync.DownloadDirs {
		p := cand
		if !filepath.IsAbs(p) {
			p = filepath.Join(root, cand)
		}
		if isDir(p) {
			add(p)
		}
	}
	// Fall back to the root itself when none of the candidates exist.
	if len(out) == 0 && isDir(root) {
		add(root)
	}
	return out
}

// ResolveDBDir returns the first existing snapshot directory for a root.
func (c *Config) ResolveDBDir(root string) string {
	for _, cand := range c.Sync.DBDirs {
		p := cand
		if !filepath.IsAbs(p) {
			p = filepath.Join(root, cand)
		}
		if isDir(p) {
			return p
		}
	}
	return ""
}

// TokenValue returns the effective token, reading TokenFile when configured.
// An explicit inline token wins.
func (c *Config) TokenValue() (string, error) {
	if strings.TrimSpace(c.Auth.Token) != "" {
		return strings.TrimSpace(c.Auth.Token), nil
	}
	if c.Auth.TokenFile == "" {
		return "", nil
	}
	raw, err := os.ReadFile(c.Auth.TokenFile)
	if err != nil {
		return "", fmt.Errorf("config: read auth.token_file %q: %w", c.Auth.TokenFile, err)
	}
	tok := strings.TrimSpace(string(raw))
	if tok == "" {
		return "", fmt.Errorf("config: auth.token_file %q is empty", c.Auth.TokenFile)
	}
	return tok, nil
}

// SessionKeyPath is where the HMAC key is stored.
func (c *Config) SessionKeyPath() string {
	return filepath.Join(c.DataDir, "session.key")
}

// IndexPath is where the on-disk index would live. Reserved for a future
// persistent index; the current build is in-memory only.
func (c *Config) IndexPath() string {
	return filepath.Join(c.DataDir, "index.json")
}

// ThumbDir is the thumbnail cache directory.
func (c *Config) ThumbDir() string {
	return filepath.Join(c.DataDir, "thumbs")
}

// RootForContainment returns the roots used for the image path containment
// check, plus whether any were configured.
func (c *Config) RootForContainment() ([]string, bool) {
	if len(c.Sync.Roots) == 0 {
		return nil, false
	}
	return c.Sync.Roots, true
}

func isDir(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.IsDir()
}

// isWithin reports whether child is inside parent (or equal to it).
func isWithin(child, parent string) bool {
	child = filepath.Clean(child)
	parent = filepath.Clean(parent)
	if child == parent {
		return true
	}
	return strings.HasPrefix(child, parent+string(os.PathSeparator))
}

// isLoopbackListen reports whether a listen address is loopback-only.
func isLoopbackListen(addr string) bool {
	host, _, err := splitHostPort(addr)
	if err != nil {
		// Unparseable: assume it is not safe.
		return false
	}
	switch host {
	case "localhost":
		return true
	case "", "::", "0.0.0.0", "[::]":
		return false
	}
	return strings.HasPrefix(host, "127.") || host == "::1" || host == "[::1]"
}

func splitHostPort(addr string) (string, string, error) {
	i := strings.LastIndex(addr, ":")
	if i < 0 {
		return addr, "", nil
	}
	return strings.Trim(addr[:i], "[]"), addr[i+1:], nil
}

// Sample renders a commented example config, used by the `sampleconfig`
// subcommand so operators do not have to read the source.
func Sample() string {
	example := `{
  // Bind loopback. The reverse proxy on the VPS is the only thing that should
  // reach this process directly.
  "listen": "127.0.0.1:8080",

  // Keep this OUTSIDE the Syncthing tree, or the index and thumbnail cache
  // get synced back to the phone.
  "data_dir": "/var/lib/ehviewer-webd",

  "sync": {
    "roots": ["/srv/ehviewer-sync/EhViewer"],
    "download_dirs": ["download"],
    "db_dirs": ["data"],
    "db_policy": "latest",
    "rescan_interval": "30m",
    "watch": true,
    "watch_debounce": "2s",
    "skip_symlinks": true,
    "max_galleries": 500000
  },

  "auth": {
    "mode": "token",
    "token_file": "/etc/ehviewer-webd/token",
    "session_ttl": "720h",
    "secure_cookies": true
  },

  "proxy": {
    "trusted_proxies": ["127.0.0.1/32"],
    "client_ip_header": "X-Forwarded-For"
  },

  "limits": {
    "write_timeout": "5m",
    "rate_limit_per_minute": 600,
    "login_rate_limit_per_minute": 10
  },

  "thumb": {
    "enabled": true,
    "max_dim": 480,
    "quality": 82,
    "workers": 2
  },

  "logging": {
    "level": "info",
    "format": "text"
  }
}
`
	return example
}
