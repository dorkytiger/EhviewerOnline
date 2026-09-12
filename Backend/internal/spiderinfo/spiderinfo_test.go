package spiderinfo

import (
	"errors"
	"strings"
	"testing"

	"github.com/warren/ehviewer-webd/internal/models"
)

// ---------------------------------------------------------------------------
// Fixture builders
//
// Hand-written fixtures repeatedly encoded the wrong line layout while writing
// these tests, because the v1 and v2 layouts differ by one line in a place
// that is easy to get backwards. Every well-formed fixture below is therefore
// produced by a serializer that mirrors SpiderInfo.write()
// (SpiderInfo.java:233-272), so a fixture can only be as wrong as the
// serializer is — and the serializer is itself covered by the round-trip
// tests.
// ---------------------------------------------------------------------------

const v2Reserved = "1" // SpiderInfo.java:246 writes a literal "1"

// formatV1 renders the version 1 layout by delegating to Format, so a fixture
// can never disagree with the serializer the parser is tested against.
func formatV1(startPage int, gid int64, token string, previewPages, pages int) string {
	text, err := Format(models.SpiderInfo{
		Version:      1,
		StartPage:    startPage,
		GID:          gid,
		Token:        token,
		PreviewPages: previewPages,
		Pages:        pages,
	})
	if err != nil {
		panic(err)
	}
	// Append pToken lines: the header parser must ignore them.
	return text + "0 abcdef\n1 0123456789\n"
}

// formatV2 renders the version 2 layout, likewise via Format.
func formatV2(startPage int, gid int64, token string, previewPages, previewPerPage, pages int) string {
	text, err := Format(models.SpiderInfo{
		Version:        2,
		StartPage:      startPage,
		GID:            gid,
		Token:          token,
		PreviewPages:   previewPages,
		PreviewPerPage: previewPerPage,
		Pages:          pages,
	})
	if err != nil {
		panic(err)
	}
	return text + "0 abcdef\n1 0123456789\n"
}

// ---------------------------------------------------------------------------
// Round trips: what the phone writes is what we read back.
// ---------------------------------------------------------------------------

func TestRoundTripV2(t *testing.T) {
	cases := []models.SpiderInfo{
		{Version: 2, StartPage: 0, GID: 1234567, Token: "deadbeef", PreviewPages: 1, PreviewPerPage: 20, Pages: 42},
		{Version: 2, StartPage: 0x1234, GID: 9, Token: "t", PreviewPages: 0, PreviewPerPage: 0, Pages: 1},
		{Version: 2, StartPage: 0xdeadbe, GID: 9223372036854775807, Token: "令牌", PreviewPages: 3, PreviewPerPage: 128, Pages: MaxPages},
	}
	for i, want := range cases {
		in := formatV2(want.StartPage, want.GID, want.Token, want.PreviewPages, want.PreviewPerPage, want.Pages)
		got, err := Parse(strings.NewReader(in))
		if err != nil {
			t.Fatalf("case %d: Parse: %v", i, err)
		}
		if *got != want {
			t.Errorf("case %d:\n got %+v\nwant %+v", i, *got, want)
		}
	}
}

func TestRoundTripV1(t *testing.T) {
	cases := []models.SpiderInfo{
		{Version: 1, StartPage: 10, GID: 7654321, Token: "cafebabe", PreviewPages: 2, Pages: 7},
		{Version: 1, StartPage: 0, GID: 1, Token: "a", PreviewPages: 0, Pages: 1},
	}
	for i, want := range cases {
		in := formatV1(want.StartPage, want.GID, want.Token, want.PreviewPages, want.Pages)
		got, err := Parse(strings.NewReader(in))
		if err != nil {
			t.Fatalf("case %d: Parse: %v\ninput=%q", i, err, in)
		}
		// PreviewPerPage is absent in v1 and stays zero.
		if *got != want {
			t.Errorf("case %d:\n got %+v\nwant %+v", i, *got, want)
		}
	}
}

// Header line layouts, asserted explicitly. This is the invariant that
// hand-written fixtures kept violating, so it is pinned with a line-by-line
// listing rather than a bare count.
//
//	v1 (6 lines):  startPage | gid | token | reserved | previewPages | pages
//	v2 (8 lines):  VERSION2 | startPage | gid | token | reserved
//	               | previewPages | previewPerPage | pages
//
// The v2 header is therefore exactly 2 lines longer: the literal VERSION2 line
// and the previewPerPage line. (v1's first line does double duty as both the
// version marker and the start page.)
func TestHeaderLayouts(t *testing.T) {
	v1Lines := []string{"00000000", "1", "tok", "1", "1", "5"}
	v2Lines := []string{"VERSION2", "00000000", "1", "tok", "1", "1", "1", "5"}

	v1 := formatV1(0, 1, "tok", 1, 5)
	v2Header := strings.TrimSuffix(formatV2(0, 1, "tok", 1, 1, 5), "0 abcdef\n1 0123456789\n")
	// v1's helper appends the same pToken tail; drop it for the layout check.
	v1Header := strings.TrimSuffix(v1, "0 abcdef\n1 0123456789\n")

	assertLines := func(name, got string, want []string) {
		t.Helper()
		lines := strings.Split(strings.TrimRight(got, "\n"), "\n")
		if len(lines) != len(want) {
			t.Fatalf("%s: got %d lines, want %d\n%s", name, len(lines), len(want), got)
		}
		for i := range want {
			if lines[i] != want[i] {
				t.Errorf("%s line %d: got %q, want %q", name, i, lines[i], want[i])
			}
		}
	}

	assertLines("v1", v1Header, v1Lines)
	assertLines("v2 header", v2Header, v2Lines)

	if d := len(v2Lines) - len(v1Lines); d != 2 {
		t.Errorf("v2 header is %d lines longer than v1, want 2", d)
	}
}

// Format is the inverse of Parse for both versions. Keeping this true means
// fixtures can be generated instead of hand-written, which removes a whole
// class of test bug (see TestHeaderLayouts).
func TestFormatParseRoundTrip(t *testing.T) {
	cases := []models.SpiderInfo{
		{Version: 1, StartPage: 10, GID: 7654321, Token: "cafebabe", PreviewPages: 2, Pages: 7},
		{Version: 2, StartPage: 0, GID: 1234567, Token: "deadbeef", PreviewPages: 1, PreviewPerPage: 20, Pages: 42},
		{Version: 2, StartPage: 0xdeadbe, GID: 9223372036854775807, Token: "令牌", PreviewPages: 3, PreviewPerPage: 128, Pages: MaxPages},
		{Version: 1, StartPage: 0, GID: 1, Token: "a", PreviewPages: 0, Pages: 1},
	}
	for i, want := range cases {
		text, err := Format(want)
		if err != nil {
			t.Fatalf("case %d: Format: %v", i, err)
		}
		got, err := Parse(strings.NewReader(text))
		if err != nil {
			t.Fatalf("case %d: Parse: %v\ntext=%q", i, err, text)
		}
		if *got != want {
			t.Errorf("case %d:\n got %+v\nwant %+v\ntext=%q", i, *got, want, text)
		}
	}
}

// Format refuses versions the parser would reject, rather than emitting a file
// that cannot be read back.
func TestFormatRejectsUnknownVersion(t *testing.T) {
	for _, v := range []int{0, 3, -1} {
		if _, err := Format(models.SpiderInfo{Version: v, GID: 1, Token: "t", Pages: 1}); err == nil {
			t.Errorf("Format accepted version %d", v)
		}
	}
}

// ---------------------------------------------------------------------------
// Version detection
// ---------------------------------------------------------------------------

func TestVersionDetection(t *testing.T) {
	cases := []struct {
		name          string
		firstLine     string
		wantVersion   int
		wantVersioned bool
	}{
		{"VERSION2", "VERSION2", 2, true},
		{"VERSION1 yields 1 but is version-prefixed", "VERSION1", 1, true},
		{"VERSION with no number yields -1", "VERSION", -1, true},
		{"VERSIONX is not a number", "VERSIONX", -1, true},
		{"VERSION3", "VERSION3", 3, true},
		{"a hex startPage means v1", "0000000a", 1, false},
		{"arbitrary text means v1", "hello", 1, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			ver, rest, versioned := parseVersion(c.firstLine)
			if ver != c.wantVersion {
				t.Errorf("version: got %d, want %d", ver, c.wantVersion)
			}
			if versioned != c.wantVersioned {
				t.Errorf("versioned: got %v, want %v", versioned, c.wantVersioned)
			}
			if rest != c.firstLine {
				t.Errorf("rest: got %q, want the line unchanged (%q)", rest, c.firstLine)
			}
		})
	}
}

// VERSION1 is the subtle one: getVersion() returns 1, but the Java dispatch
// only accepts 1 when the line did NOT carry a VERSION prefix. Such a file
// must be rejected rather than read as an unversioned v1 file.
func TestVersion1LiteralIsRejected(t *testing.T) {
	_, err := Parse(strings.NewReader("VERSION1\n00000000\n1\ntok\n1\n1\n1\n1\n"))
	if err == nil {
		t.Fatal("expected VERSION1 to be rejected")
	}
	if !errors.Is(err, ErrInvalid) {
		t.Fatalf("expected ErrInvalid, got %v", err)
	}
}

// ---------------------------------------------------------------------------
// getStartPage: a fold, not a positional decode
// ---------------------------------------------------------------------------

// getStartPage() multiplies by 16 on EVERY character and only adds a value for
// [0-9a-f]. A non-hex character therefore still shifts the accumulator; it is
// not a separator and it does not terminate the number.
func TestStartPageIsAFold(t *testing.T) {
	cases := []struct {
		in   string
		want int
	}{
		{"00000001", 1},
		{"000f", 15},
		{"zzzz", 0},
		{"12-34", 0x12034}, // 1, 0x12, 0x120, 0x1203, 0x12034
		{"1-2", 0x102},     // 1, 0x10, 0x102
		{"f", 15},
		{"0f", 15},
		{"ff", 255},
		{"ABCDEF", 0}, // uppercase is NOT accepted by the Java scan
		{"", 0},
	}
	for _, c := range cases {
		if got := parseHexLoose(c.in); got != c.want {
			t.Errorf("parseHexLoose(%q) = 0x%x, want 0x%x", c.in, got, c.want)
		}
	}
}

// The start page reaches Parse() through the same path.
func TestStartPageThroughParse(t *testing.T) {
	got, err := Parse(strings.NewReader(formatV2(0xbeef, 42, "tok", 1, 1, 3)))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if got.StartPage != 0xbeef {
		t.Errorf("startPage: got 0x%x, want 0xbeef", got.StartPage)
	}
}

// ---------------------------------------------------------------------------
// Malformed input
// ---------------------------------------------------------------------------

func TestInvalidFiles(t *testing.T) {
	cases := []struct {
		name string
		in   string
	}{
		{"empty input", ""},
		{"version 3", "VERSION3\n00000000\n1\ntok\n1\n1\n1\n1\n"},
		{"version 1 literal is rejected", "VERSION1\n00000000\n1\ntok\n1\n1\n1\n1\n"},
		{"version with garbage suffix", "VERSIONX\n00000000\n1\ntok\n1\n1\n1\n1\n"},
		{"truncated after version", "VERSION2\n00000000\n"},
		{"missing token", "VERSION2\n00000000\n1234567\n"},
		{"pages zero", formatV2(0, 1234567, "tok", 1, 20, 0)},
		{"pages negative", formatV2(0, 1234567, "tok", 1, 20, -1)},
		{"pages above cap", formatV2(0, 1234567, "tok", 1, 20, MaxPages+1)},
		{"pages not a number", "VERSION2\n00000000\n1234567\ntok\n1\n1\n20\nabc\n"},
		{"gid not a number", "VERSION2\n00000000\nabc\ntok\n1\n1\n20\n5\n"},
		{"gid overflow", "VERSION2\n00000000\n99999999999999999999\ntok\n1\n1\n20\n5\n"},
		{"line too long", "VERSION2\n" + strings.Repeat("0", MaxHeaderLineChars+10) + "\n1\ntok\n1\n1\n1\n1\n"},
		// A v1 header cut short before its final `pages` field. Note that
		// dropping only the trailing pToken lines is still a valid file, so
		// this must truncate the header itself.
		{"v1 missing pages", "0000000a\n7654321\ntok\nANYTHING\n2\n"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := Parse(strings.NewReader(c.in))
			if err == nil {
				t.Fatal("expected an error, got nil")
			}
			if !errors.Is(err, ErrInvalid) {
				t.Fatalf("expected ErrInvalid, got %v", err)
			}
		})
	}
}

// The pages bound is inclusive.
func TestPagesAtCapIsValid(t *testing.T) {
	got, err := Parse(strings.NewReader(formatV2(0, 1, "tok", 1, 20, MaxPages)))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if got.Pages != MaxPages {
		t.Errorf("pages: got %d, want %d", got.Pages, MaxPages)
	}
}

// ---------------------------------------------------------------------------
// Tolerances
// ---------------------------------------------------------------------------

func TestCRLFAndMissingTrailingNewline(t *testing.T) {
	in := strings.ReplaceAll(formatV2(0, 1234567, "tok", 1, 20, 5), "\n", "\r\n")
	in = strings.TrimSuffix(in, "\r\n") // drop the final terminator too
	got, err := Parse(strings.NewReader(in))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if got.Pages != 5 || got.PreviewPerPage != 20 || got.Token != "tok" || got.GID != 1234567 {
		t.Errorf("unexpected result: %+v", *got)
	}
}

func TestBlankLinesSkipped(t *testing.T) {
	// Interleave blank lines into a valid v2 document; every field must land
	// in the same place.
	lines := strings.Split(strings.TrimRight(formatV2(0x11, 1234567, "tok", 1, 20, 5), "\n"), "\n")
	in := "\n" + strings.Join(lines, "\n\n") + "\n"
	got, err := Parse(strings.NewReader(in))
	if err != nil {
		t.Fatalf("Parse: %v\ninput=%q", err, in)
	}
	if got.StartPage != 0x11 || got.GID != 1234567 || got.Token != "tok" ||
		got.PreviewPages != 1 || got.PreviewPerPage != 20 || got.Pages != 5 {
		t.Errorf("blank lines shifted fields: %+v", *got)
	}
}

// nextInt mirrors parseIntSafely, a bare Integer.parseInt, which tolerates a
// leading plus and surrounding whitespace.
func TestIntegerParsingMatchesJava(t *testing.T) {
	in := "VERSION2\n00000000\n1234567\ntok\n1\n 1 \n+20\n5\n"
	got, err := Parse(strings.NewReader(in))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if got.PreviewPages != 1 || got.PreviewPerPage != 20 {
		t.Errorf("got previewPages=%d previewPerPage=%d, want 1 and 20",
			got.PreviewPages, got.PreviewPerPage)
	}
}

// A UTF-8 token must survive intact.
func TestUTF8Token(t *testing.T) {
	got, err := Parse(strings.NewReader(formatV2(0, 1234567, "令牌-テスト", 1, 20, 5)))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if got.Token != "令牌-テスト" {
		t.Errorf("token: got %q", got.Token)
	}
}

// The reserved line's content is ignored, so a v1 file may put anything there.
func TestReservedLineContentIgnored(t *testing.T) {
	got, err := Parse(strings.NewReader("0000000a\n7654321\ntok\nANYTHING\n2\n7\n"))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if got.GID != 7654321 || got.Token != "tok" || got.PreviewPages != 2 || got.Pages != 7 {
		t.Errorf("reserved line leaked into fields: %+v", *got)
	}
}
