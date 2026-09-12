package auth

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func newTestManager(t *testing.T, token string) *Manager {
	t.Helper()
	m, err := New(Options{
		Mode:          ModeToken,
		Token:         token,
		KeyPath:       filepath.Join(t.TempDir(), "session.key"),
		CookieName:    "ehw_session",
		TTL:           time.Hour,
		SecureCookies: true,
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return m
}

func TestIssueAndVerify(t *testing.T) {
	m := newTestManager(t, "secret")

	value, err := m.Issue()
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}
	if !strings.Contains(value, ".") {
		t.Fatalf("session value should be payload.signature, got %q", value)
	}

	p, err := m.Verify(value)
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if p.Subject != "owner" {
		t.Errorf("subject: got %q", p.Subject)
	}
	if p.Expires <= p.Issued {
		t.Errorf("expiry should be after issue: iat=%d exp=%d", p.Issued, p.Expires)
	}
}

// A tampered payload or signature must never verify.
func TestVerifyRejectsTampering(t *testing.T) {
	m := newTestManager(t, "secret")
	value, err := m.Issue()
	if err != nil {
		t.Fatal(err)
	}
	payload, sig, _ := strings.Cut(value, ".")

	// Assert the tampering actually changes the string, so this test cannot
	// pass vacuously if a helper is wrong.
	swappedSig := sig[:len(sig)-1] + "A"
	if swappedSig == sig {
		t.Fatalf("swappedSig equals the original %q; the test is broken", sig)
	}
	flippedPayload := flipLast(payload)
	if flippedPayload == payload {
		t.Fatalf("flippedPayload equals the original; the test is broken")
	}
	t.Logf("sig len=%d last=%q swapped last=%q", len(sig), sig[len(sig)-1], swappedSig[len(swappedSig)-1])

	cases := map[string]string{
		"empty":             "",
		"no separator":      "abcdef",
		"empty payload":     "." + sig,
		"empty signature":   payload + ".",
		"truncated sig":     payload + "." + sig[:len(sig)-1],
		"extra sig char":    payload + "." + sig + "A",
		"flipped sig byte":  payload + "." + flipLast(sig),
		"swapped signature": payload + "." + swappedSig,
		"payload swapped":   flippedPayload + "." + sig,
		"garbage payload":   "notbase64!!." + sig,
	}
	for name, v := range cases {
		t.Run(name, func(t *testing.T) {
			if v == value {
				t.Fatalf("case %q uses the untampered value", name)
			}
			if _, err := m.Verify(v); err == nil {
				t.Errorf("Verify(%q) accepted a tampered session", v)
			}
		})
	}
}

func flipLast(s string) string {
	if s == "" {
		return "x"
	}
	last := s[len(s)-1]
	if last == 'A' {
		last = 'B'
	} else {
		last = 'A'
	}
	return s[:len(s)-1] + string(last)
}

// A signature from one key must not verify under another, which is what makes
// an ephemeral key safe-by-default across restarts.
func TestVerifyRejectsForeignKey(t *testing.T) {
	a := newTestManager(t, "secret")
	b := newTestManager(t, "secret")

	value, err := a.Issue()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := b.Verify(value); err == nil {
		t.Error("a session signed by another key must not verify")
	}
}

func TestVerifyRejectsExpiredSession(t *testing.T) {
	now := time.Now()
	keyPath := filepath.Join(t.TempDir(), "session.key")

	m, err := New(Options{
		Mode: ModeToken, Token: "s", KeyPath: keyPath, TTL: time.Minute,
		Now: func() time.Time { return now },
	})
	if err != nil {
		t.Fatal(err)
	}
	value, err := m.Issue()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := m.Verify(value); err != nil {
		t.Fatalf("the session should still be valid: %v", err)
	}

	// Move time past the expiry using the same key.
	later := now.Add(2 * time.Minute)
	m2, err := New(Options{
		Mode: ModeToken, Token: "s", KeyPath: keyPath, TTL: time.Minute,
		Now: func() time.Time { return later },
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := m2.Verify(value); err == nil {
		t.Error("an expired session must be rejected")
	}
}

func TestCheckToken(t *testing.T) {
	m := newTestManager(t, "correct-horse")

	if err := m.CheckToken("correct-horse"); err != nil {
		t.Errorf("the right token should be accepted: %v", err)
	}
	for _, bad := range []string{"", "Correct-Horse", "correct-hors", "correct-horse ", "x"} {
		if err := m.CheckToken(bad); !errors.Is(err, ErrBadToken) {
			t.Errorf("CheckToken(%q) = %v, want ErrBadToken", bad, err)
		}
	}
}

// With no token configured, CheckToken must refuse everything rather than
// treating an empty presented token as a match.
func TestCheckTokenWithoutConfiguredToken(t *testing.T) {
	m, err := New(Options{Mode: ModeNone, KeyPath: filepath.Join(t.TempDir(), "k")})
	if err != nil {
		t.Fatal(err)
	}
	if err := m.CheckToken(""); !errors.Is(err, ErrNoTokenSet) {
		t.Errorf("got %v, want ErrNoTokenSet", err)
	}
	if err := m.CheckToken("anything"); !errors.Is(err, ErrNoTokenSet) {
		t.Errorf("got %v, want ErrNoTokenSet", err)
	}
}

func TestNewRejectsTokenModeWithoutToken(t *testing.T) {
	if _, err := New(Options{Mode: ModeToken, KeyPath: filepath.Join(t.TempDir(), "k")}); !errors.Is(err, ErrNoTokenSet) {
		t.Errorf("got %v, want ErrNoTokenSet", err)
	}
}

func TestNewRejectsUnknownMode(t *testing.T) {
	if _, err := New(Options{Mode: "password", KeyPath: filepath.Join(t.TempDir(), "k")}); err == nil {
		t.Error("expected an error for an unknown mode")
	}
}

func TestSessionKeyIsPersistedAndReloaded(t *testing.T) {
	keyPath := filepath.Join(t.TempDir(), "session.key")

	a, err := New(Options{Mode: ModeToken, Token: "s", KeyPath: keyPath})
	if err != nil {
		t.Fatal(err)
	}
	value, err := a.Issue()
	if err != nil {
		t.Fatal(err)
	}

	// A second manager reading the same key file must accept the session, so
	// a restart does not log the user out.
	b, err := New(Options{Mode: ModeToken, Token: "s", KeyPath: keyPath})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := b.Verify(value); err != nil {
		t.Errorf("a session should survive a restart: %v", err)
	}

	fi, err := os.Stat(keyPath)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Size() < 32 {
		t.Errorf("session key is too short: %d bytes", fi.Size())
	}
	// Go ignores Unix permission bits on Windows, where the file inherits the
	// directory ACL instead. The deployment target is Linux, so the check is
	// only meaningful there; asserting it on Windows would fail for a reason
	// that has nothing to do with this code.
	if runtime.GOOS != "windows" {
		if perm := fi.Mode().Perm(); perm&0o077 != 0 {
			t.Errorf("session key permissions are too open: %v, want 0600", perm)
		}
	}

	// A short or corrupt key file must be replaced, not trusted.
	if err := os.WriteFile(keyPath, []byte("short"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := New(Options{Mode: ModeToken, Token: "s", KeyPath: keyPath}); err != nil {
		t.Errorf("New should regenerate an unusable key: %v", err)
	}
}

// --- cookie attributes -----------------------------------------------------

func TestCookieAttributes(t *testing.T) {
	m := newTestManager(t, "secret")
	rec := httptest.NewRecorder()
	m.SetCookie(rec, "value")

	cookies := rec.Result().Cookies()
	if len(cookies) != 1 {
		t.Fatalf("got %d cookies", len(cookies))
	}
	c := cookies[0]
	if c.Name != "ehw_session" {
		t.Errorf("name: got %q", c.Name)
	}
	if !c.HttpOnly {
		t.Error("the session cookie must be HttpOnly")
	}
	if !c.Secure {
		t.Error("the session cookie must be Secure behind HTTPS")
	}
	if c.SameSite != http.SameSiteLaxMode {
		t.Errorf("SameSite: got %v, want Lax", c.SameSite)
	}
	// A Domain attribute would widen the cookie to sibling hosts; there is
	// exactly one host.
	if c.Domain != "" {
		t.Errorf("the cookie must be host-only, got Domain=%q", c.Domain)
	}
	if c.Path != "/" {
		t.Errorf("path: got %q", c.Path)
	}
}

func TestClearCookieExpiresIt(t *testing.T) {
	m := newTestManager(t, "secret")
	rec := httptest.NewRecorder()
	m.ClearCookie(rec)

	cookies := rec.Result().Cookies()
	if len(cookies) != 1 {
		t.Fatalf("got %d cookies", len(cookies))
	}
	if cookies[0].MaxAge >= 0 {
		t.Errorf("clearing should set MaxAge<0, got %d", cookies[0].MaxAge)
	}
	if cookies[0].Value != "" {
		t.Errorf("clearing should blank the value, got %q", cookies[0].Value)
	}
}

// --- middleware ------------------------------------------------------------

func TestMiddlewareModeNoneAllowsEverything(t *testing.T) {
	m, err := New(Options{Mode: ModeNone, KeyPath: filepath.Join(t.TempDir(), "k")})
	if err != nil {
		t.Fatal(err)
	}
	called := false
	h := m.Middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called = true
		w.WriteHeader(http.StatusTeapot)
	}))

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/anything", nil))
	if !called || rec.Code != http.StatusTeapot {
		t.Errorf("mode none should pass through: called=%v code=%d", called, rec.Code)
	}
}

func TestMiddlewareRejectsWithoutSession(t *testing.T) {
	m := newTestManager(t, "secret")
	h := m.Middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("the wrapped handler must not run")
	}))

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/galleries", nil))

	if rec.Code != http.StatusUnauthorized {
		t.Errorf("status: got %d, want 401", rec.Code)
	}
	// A bare 401 gives a scanner nothing: no body, no challenge header, no
	// hint that the route exists.
	if rec.Body.Len() != 0 {
		t.Errorf("body should be empty, got %q", rec.Body.String())
	}
	if rec.Header().Get("WWW-Authenticate") != "" {
		t.Error("no WWW-Authenticate header should be advertised")
	}
	if cc := rec.Header().Get("Cache-Control"); cc != "no-store" {
		t.Errorf("Cache-Control: got %q, want no-store", cc)
	}
}

func TestMiddlewareAcceptsValidSession(t *testing.T) {
	m := newTestManager(t, "secret")
	value, err := m.Issue()
	if err != nil {
		t.Fatal(err)
	}

	called := false
	h := m.Middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called = true
		w.WriteHeader(http.StatusNoContent)
	}))

	req := httptest.NewRequest(http.MethodGet, "/api/v1/galleries", nil)
	req.AddCookie(&http.Cookie{Name: "ehw_session", Value: value})
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if !called || rec.Code != http.StatusNoContent {
		t.Errorf("a valid session should pass: called=%v code=%d", called, rec.Code)
	}
}

func TestSessionFrom(t *testing.T) {
	m := newTestManager(t, "secret")
	value, err := m.Issue()
	if err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	if _, err := m.SessionFrom(req); !errors.Is(err, ErrNoSession) {
		t.Errorf("got %v, want ErrNoSession", err)
	}

	req.AddCookie(&http.Cookie{Name: "ehw_session", Value: value})
	if _, err := m.SessionFrom(req); err != nil {
		t.Errorf("got %v, want a valid session", err)
	}
}

func TestAuthenticatedReflectsMode(t *testing.T) {
	none, err := New(Options{Mode: ModeNone, KeyPath: filepath.Join(t.TempDir(), "k")})
	if err != nil {
		t.Fatal(err)
	}
	if !none.Authenticated(httptest.NewRequest(http.MethodGet, "/", nil)) {
		t.Error("mode none should report every request as authenticated")
	}

	tok := newTestManager(t, "secret")
	if tok.Authenticated(httptest.NewRequest(http.MethodGet, "/", nil)) {
		t.Error("token mode should not authenticate an anonymous request")
	}
}

// --- token generation ------------------------------------------------------

func TestGenerateToken(t *testing.T) {
	a, err := GenerateToken(32)
	if err != nil {
		t.Fatal(err)
	}
	b, err := GenerateToken(32)
	if err != nil {
		t.Fatal(err)
	}
	if a == b {
		t.Error("two generated tokens must differ")
	}
	// 32 bytes base64url-encoded without padding is 43 characters.
	if len(a) != 43 {
		t.Errorf("length: got %d, want 43", len(a))
	}
	if strings.ContainsAny(a, "+/=") {
		t.Errorf("token must be URL-safe, got %q", a)
	}

	// A zero or negative size falls back to a sane default rather than
	// producing an empty token.
	short, err := GenerateToken(0)
	if err != nil {
		t.Fatal(err)
	}
	if len(short) < 16 {
		t.Errorf("default token is too short: %q", short)
	}
}
