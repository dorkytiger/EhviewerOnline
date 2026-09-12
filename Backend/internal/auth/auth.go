// Package auth implements the single-user session model.
//
// Scope is deliberately small. This is a personal service exposed through frp,
// so the goal is not defence in depth but making sure the set of people who can
// reach the content stays exactly one (design doc §8.1). Concretely that means:
//
//   - a strong shared token, compared in constant time;
//   - a signed, expiring session cookie (no server-side session table);
//   - authentication applied to every route that can reveal content, images
//     and the SSE stream included, because /img/<gid>/<index> is enumerable.
//
// Not implemented on purpose: 2FA, per-user accounts, password reset, lockout
// beyond what the reverse proxy does, and CSRF tokens. There is no state to
// protect beyond "can this person read the library", and the cookie is
// SameSite=Lax on a single origin.
package auth

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Mode selects how (or whether) requests are authenticated.
type Mode string

const (
	// ModeNone disables authentication. Only safe when the listener is bound
	// to loopback; the config loader enforces that.
	ModeNone Mode = "none"
	// ModeToken requires a session cookie obtained by presenting the token.
	ModeToken Mode = "token"
)

// Errors returned by the session manager.
var (
	ErrNoSession   = errors.New("auth: no valid session")
	ErrBadToken    = errors.New("auth: token mismatch")
	ErrNoTokenSet  = errors.New("auth: no token is configured")
	ErrKeyUnusable = errors.New("auth: session key is unusable")
)

// SessionPayload is the cookie's signed body. Deliberately minimal: a subject
// marker and the validity window.
type SessionPayload struct {
	Subject string `json:"sub"`
	Issued  int64  `json:"iat"`
	Expires int64  `json:"exp"`
}

// Manager issues and verifies session cookies.
type Manager struct {
	mode       Mode
	key        []byte
	cookieName string
	ttl        time.Duration
	token      []byte // shared secret; empty when not configured
	now        func() time.Time

	// SecureCookies marks the cookie Secure. It must be true behind frp+
	// HTTPS; the config loader defaults it on and only permits false for
	// loopback testing.
	SecureCookies bool
	// CookiePath defaults to "/".
	CookiePath string
}

// Options configures a Manager.
type Options struct {
	Mode Mode
	// Token is the shared secret. Required for ModeToken.
	Token string
	// KeyPath is where the HMAC key is persisted. Created if absent.
	KeyPath string
	// CookieName defaults to "ehw_session".
	CookieName string
	// TTL defaults to 30 days.
	TTL time.Duration
	// SecureCookies should be true in production.
	SecureCookies bool
	// Now is injectable for tests.
	Now func() time.Time
}

// New builds a Manager, creating the session key file if needed.
func New(opts Options) (*Manager, error) {
	if opts.Mode == "" {
		opts.Mode = ModeNone
	}
	if opts.Mode != ModeNone && opts.Mode != ModeToken {
		return nil, fmt.Errorf("auth: unknown mode %q", opts.Mode)
	}
	if opts.CookieName == "" {
		opts.CookieName = "ehw_session"
	}
	if opts.TTL <= 0 {
		opts.TTL = 30 * 24 * time.Hour
	}
	if opts.Now == nil {
		opts.Now = time.Now
	}

	m := &Manager{
		mode:          opts.Mode,
		cookieName:    opts.CookieName,
		ttl:           opts.TTL,
		now:           opts.Now,
		SecureCookies: opts.SecureCookies,
		CookiePath:    "/",
	}

	if opts.Mode == ModeToken {
		if strings.TrimSpace(opts.Token) == "" {
			return nil, ErrNoTokenSet
		}
		m.token = []byte(strings.TrimSpace(opts.Token))
	}

	key, err := loadOrCreateKey(opts.KeyPath)
	if err != nil {
		return nil, err
	}
	m.key = key
	return m, nil
}

// Mode returns the configured mode.
func (m *Manager) Mode() Mode { return m.mode }

// CookieName returns the session cookie name.
func (m *Manager) CookieName() string { return m.cookieName }

// TTL returns the session lifetime.
func (m *Manager) TTL() time.Duration { return m.ttl }

// GenerateToken returns a fresh URL-safe random token of n bytes of entropy.
// Used by the `gentoken` subcommand.
func GenerateToken(n int) (string, error) {
	if n <= 0 {
		n = 32
	}
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("auth: read random: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(buf), nil
}

func loadOrCreateKey(path string) ([]byte, error) {
	if path == "" {
		// Ephemeral key: sessions do not survive a restart, which is an
		// acceptable fallback but worth avoiding.
		key := make([]byte, 32)
		if _, err := rand.Read(key); err != nil {
			return nil, fmt.Errorf("auth: read random: %w", err)
		}
		return key, nil
	}
	if b, err := os.ReadFile(path); err == nil && len(b) >= 32 {
		return b, nil
	}
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		return nil, fmt.Errorf("auth: read random: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("auth: create key dir: %w", err)
	}
	if err := os.WriteFile(path, key, 0o600); err != nil {
		return nil, fmt.Errorf("auth: write key: %w", err)
	}
	return key, nil
}

// Issue creates a signed session value.
func (m *Manager) Issue() (string, error) {
	if len(m.key) < 32 {
		return "", ErrKeyUnusable
	}
	now := m.now()
	p := SessionPayload{
		Subject: "owner",
		Issued:  now.Unix(),
		Expires: now.Add(m.ttl).Unix(),
	}
	body, err := json.Marshal(p)
	if err != nil {
		return "", err
	}
	enc := base64.RawURLEncoding.EncodeToString(body)
	sig := m.sign(enc)
	return enc + "." + sig, nil
}

// Verify checks a session value and returns the payload.
func (m *Manager) Verify(value string) (*SessionPayload, error) {
	enc, sig, ok := strings.Cut(value, ".")
	if !ok || enc == "" || sig == "" {
		return nil, ErrNoSession
	}
	want := m.sign(enc)
	// Constant-time compare so a forged signature cannot be discovered
	// byte-by-byte.
	if subtle.ConstantTimeCompare([]byte(sig), []byte(want)) != 1 {
		return nil, ErrNoSession
	}
	raw, err := base64.RawURLEncoding.DecodeString(enc)
	if err != nil {
		return nil, ErrNoSession
	}
	var p SessionPayload
	if err := json.Unmarshal(raw, &p); err != nil {
		return nil, ErrNoSession
	}
	if p.Expires <= m.now().Unix() {
		return nil, ErrNoSession
	}
	return &p, nil
}

func (m *Manager) sign(payloadB64 string) string {
	mac := hmac.New(sha256.New, m.key)
	mac.Write([]byte(payloadB64))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

// CheckToken compares a presented token against the configured one in constant
// time. It returns ErrNoTokenSet when token mode is not configured, so callers
// never accidentally accept any input.
func (m *Manager) CheckToken(presented string) error {
	if len(m.token) == 0 {
		return ErrNoTokenSet
	}
	if subtle.ConstantTimeCompare([]byte(presented), m.token) != 1 {
		return ErrBadToken
	}
	return nil
}

// SetCookie writes the session cookie.
//
// Attributes and why:
//   - HttpOnly: the client never needs to read it, so XSS cannot exfiltrate it.
//   - Secure: required, we are behind HTTPS.
//   - SameSite=Lax: the web client is same-origin, so <img> and EventSource
//     both send the cookie, while cross-site POSTs do not. Strict would drop
//     the cookie when arriving from an external link.
//   - No Domain attribute: host-only is narrower, and there is exactly one host.
func (m *Manager) SetCookie(w http.ResponseWriter, value string) {
	http.SetCookie(w, &http.Cookie{
		Name:     m.cookieName,
		Value:    value,
		Path:     m.CookiePath,
		MaxAge:   int(m.ttl.Seconds()),
		HttpOnly: true,
		Secure:   m.SecureCookies,
		SameSite: http.SameSiteLaxMode,
	})
}

// ClearCookie expires the session cookie.
func (m *Manager) ClearCookie(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{
		Name:     m.cookieName,
		Value:    "",
		Path:     m.CookiePath,
		MaxAge:   -1,
		HttpOnly: true,
		Secure:   m.SecureCookies,
		SameSite: http.SameSiteLaxMode,
	})
}

// SessionFrom extracts and verifies the session from a request.
func (m *Manager) SessionFrom(r *http.Request) (*SessionPayload, error) {
	c, err := r.Cookie(m.cookieName)
	if err != nil || c.Value == "" {
		return nil, ErrNoSession
	}
	return m.Verify(c.Value)
}

// Authenticated reports whether the request carries a valid session. In
// ModeNone it is always true.
func (m *Manager) Authenticated(r *http.Request) bool {
	if m.mode == ModeNone {
		return true
	}
	_, err := m.SessionFrom(r)
	return err == nil
}

// Middleware rejects unauthenticated requests.
//
// Every content-bearing route goes through this, including images and the SSE
// stream. The failure mode to avoid is protecting /api but leaving /img open:
// gallery ids are small integers, so an unauthenticated image endpoint is an
// enumerable content dump.
//
// The rejection is a bare 401 with no body and no WWW-Authenticate header: it
// gives an unauthenticated scanner nothing to work with.
func (m *Manager) Middleware(next http.Handler) http.Handler {
	if m.mode == ModeNone {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !m.Authenticated(r) {
			w.Header().Set("Cache-Control", "no-store")
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}
