// Package spiderinfo parses the ".ehviewer" file that EhViewer writes into
// every gallery download directory.
//
// The format is defined by
// app/src/main/java/com/hippo/ehviewer/spider/SpiderInfo.java (write() at
// lines 233-272, parseHeader() at 182-208, getStartPage() at 112-129,
// getVersion() at 131-140). This parser reproduces the Java behaviour
// byte-for-byte for every quirk that is observable, including:
//
//   - the bracketed hex scan in getStartPage(), which silently ignores any
//     non-hex character instead of failing;
//   - parseIntSafely() (NumberUtils.java:50-56) being a bare
//     Integer.parseInt, so "VERSION" alone yields the default -1 and is
//     therefore treated as a version 1 file, while "VERSIONX" makes the whole
//     file invalid;
//   - the valid range check 0 < pages <= 100000 (SpiderInfo.java:204-206);
//   - the 8192 character per-line cap (MAX_SPIDER_INFO_HEADER_LINE).
//
// Only the header is parsed. The per-page pToken lines that follow are used
// solely to resume downloads on the phone and are of no use here.
package spiderinfo

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/warren/ehviewer-webd/internal/models"
)

// FileName is the metadata file inside each gallery directory
// (SpiderQueen.SPIDER_INFO_FILENAME).
const FileName = ".ehviewer"

// MaxHeaderLineChars mirrors MAX_SPIDER_INFO_HEADER_LINE. The Java side bounds
// character count, not bytes; we convert bytes to runes before comparing.
const MaxHeaderLineChars = 8192

// MaxPages mirrors MAX_SPIDER_INFO_PAGES.
const MaxPages = 100_000

// ErrInvalid reports a file that parses far enough to be recognized but fails
// a structural check. Callers should treat it like the Java code treats a nil
// SpiderInfo: skip the file, do not abort the scan.
var ErrInvalid = errors.New("spiderinfo: invalid metadata file")

// Parse reads and validates a .ehviewer header.
//
// A nil error means the file is usable. ErrInvalid (possibly wrapped) means
// the file should be ignored, which matches SpiderInfo.read() returning null.
func Parse(r io.Reader) (*models.SpiderInfo, error) {
	sc := newLineScanner(r)

	line, err := sc.next()
	if err != nil {
		return nil, fmt.Errorf("%w: cannot read version line: %v", ErrInvalid, err)
	}

	// This mirrors SpiderInfo.java:187-193, an if/else-if chain (NOT a switch):
	//
	//	if (version == VERSION) { line = readLine(); }   // v2: separate startPage
	//	else if (version == 1) { /* pass */ }            // v1: no extra line
	//	else return null;
	//
	// Go's switch does not fall through the way Java's else-if does, so the
	// start-page handling here and the unconditional reserved-line read at
	// line 197 are kept deliberately separate.
	version, line, versioned := parseVersion(line)
	if version != 1 && version != 2 {
		return nil, fmt.Errorf("%w: unsupported version %d", ErrInvalid, version)
	}
	if version == 1 && versioned {
		// "VERSION1": getVersion() yields 1, but the version==1 branch means
		// "first line was not a VERSION line", so this is malformed.
		return nil, fmt.Errorf("%w: unsupported version 1 with a VERSION prefix", ErrInvalid)
	}
	if version == 2 {
		line, err = sc.next()
		if err != nil {
			return nil, fmt.Errorf("%w: cannot read start page: %v", ErrInvalid, err)
		}
	}

	info := &models.SpiderInfo{Version: version}
	info.StartPage = parseHexLoose(line)

	gidLine, err := sc.next()
	if err != nil {
		return nil, fmt.Errorf("%w: cannot read gid: %v", ErrInvalid, err)
	}
	gid, err := strconv.ParseInt(strings.TrimSpace(gidLine), 10, 64)
	if err != nil {
		return nil, fmt.Errorf("%w: bad gid %q", ErrInvalid, gidLine)
	}
	info.GID = gid

	token, err := sc.next()
	if err != nil {
		return nil, fmt.Errorf("%w: cannot read token: %v", ErrInvalid, err)
	}
	info.Token = token

	// SpiderInfo.java:197 — the reserved "1" line is read and discarded.
	//
	// This runs for BOTH versions and is unconditional in the Java source.
	// For v2 it is the line following the token. For v1 the version line has
	// already served as the start page, so this read consumes the first line
	// after the token, i.e. the reserved slot. Either way exactly one line is
	// spent here.
	if _, err := sc.next(); err != nil {
		return nil, fmt.Errorf("%w: cannot read reserved line: %v", ErrInvalid, err)
	}

	previewPages, err := sc.nextInt("preview pages")
	if err != nil {
		return nil, err
	}
	info.PreviewPages = previewPages

	if version == 2 {
		previewPerPage, err := sc.nextInt("preview pages per page")
		if err != nil {
			return nil, err
		}
		info.PreviewPerPage = previewPerPage
	}

	pages, err := sc.nextInt("pages")
	if err != nil {
		return nil, err
	}
	if pages <= 0 || pages > MaxPages {
		return nil, fmt.Errorf("%w: pages out of range: %d", ErrInvalid, pages)
	}
	info.Pages = pages

	return info, nil
}

// Format renders a .ehviewer header exactly as SpiderInfo.write()
// (SpiderInfo.java:233-272) does, for the given version.
//
// Only the header is written; the pToken lines that the phone appends are
// deliberately omitted, since this service never reads them. The output is
// therefore always parseable by Parse, which is what makes it useful for
// fixtures, tooling and round-trip verification.
//
// version 1 is rendered without a VERSION prefix and without a dedicated
// startPage line, matching getVersion()'s "no prefix means 1" rule.
func Format(info models.SpiderInfo) (string, error) {
	if info.Version != 1 && info.Version != 2 {
		return "", fmt.Errorf("spiderinfo: cannot format version %d", info.Version)
	}
	var b strings.Builder
	writeLine := func(s string) {
		b.WriteString(s)
		b.WriteByte('\n')
	}

	if info.Version == 2 {
		writeLine("VERSION2")
	}
	// v1 uses this line as both the version marker and the start page.
	writeLine(fmt.Sprintf("%08x", max(info.StartPage, 0)))
	writeLine(strconv.FormatInt(info.GID, 10))
	writeLine(info.Token)
	writeLine("1") // reserved, always "1" (SpiderInfo.java:246)
	writeLine(strconv.Itoa(info.PreviewPages))
	if info.Version == 2 {
		writeLine(strconv.Itoa(info.PreviewPerPage))
	}
	writeLine(strconv.Itoa(info.Pages))

	return b.String(), nil
}

// parseVersion mirrors getVersion() / the version dispatch in parseHeader().
//
// The Java code has two distinct notions that are easy to conflate:
//
//	getVersion(str):  str starts with "VERSION" -> parseInt(rest, default -1),
//	                  otherwise                  -> 1
//	if (version == 2)      { line = readLine(); }  // only 2 triggers a read
//	else if (version == 1) { /* pass */ }          // only 1 is accepted as v1
//	else                   { return null; }        // 0, 3, -1, ... rejected
//
// Because the second test is `version == 1` and not "did not start with
// VERSION", a file whose first line is literally "VERSION1" is REJECTED: it
// yields version 1 from getVersion, but it would then be read as a v1 file
// whose start page line was "VERSION1" — which the Java code does not do,
// since v1 never has a VERSION prefix.
//
// versioned is true when the line carried a "VERSION" prefix, which is what
// separates a real v1 file from a malformed VERSION-prefixed one.
func parseVersion(line string) (version int, rest string, versioned bool) {
	const prefix = "VERSION"
	if len(line) >= len(prefix) && line[:len(prefix)] == prefix {
		// NumberUtils.parseIntSafely(rest, -1) is a bare Integer.parseInt,
		// which still tolerates surrounding whitespace but nothing else. So
		// "VERSION2" is fine, "VERSION " is not (empty remainder -> -1), and
		// "VERSIONX" is not either.
		n, err := parseIntJava(line[len(prefix):])
		if err != nil {
			return -1, line, true
		}
		return n, line, true
	}
	// Not a version line at all: it doubles as the startPage line of a v1 file.
	return 1, line, false
}

// parseIntJava mirrors java.lang.Integer/Long.parseLong acceptance: optional
// sign, digits only, with optional surrounding whitespace. strconv alone is
// stricter (it rejects leading "+" and surrounding spaces), and being
// stricter than the phone would mean rejecting files EhViewer accepts.
func parseIntJava(s string) (int, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, strconv.ErrSyntax
	}
	body := s
	if body[0] == '+' || body[0] == '-' {
		body = body[1:]
	}
	if body == "" {
		return 0, strconv.ErrSyntax
	}
	for i := 0; i < len(body); i++ {
		if body[i] < '0' || body[i] > '9' {
			return 0, strconv.ErrSyntax
		}
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		return 0, err
	}
	return n, nil
}

// parseHexLoose mirrors getStartPage(): iterate the runes, multiplying by 16
// on every step, and add only [0-9a-f]. A non-hex character therefore still
// shifts the accumulator rather than terminating the number, so "12-34" folds
// to 0x12034 and not 0x1234. The result is clamped at zero.
func parseHexLoose(s string) int {
	n := 0
	for _, r := range s {
		n *= 16
		switch {
		case r >= '0' && r <= '9':
			n += int(r - '0')
		case r >= 'a' && r <= 'f':
			n += int(r-'a') + 10
		}
	}
	if n < 0 {
		return 0
	}
	return n
}

type lineScanner struct {
	br     *bufio.Reader
	lineno int
}

func newLineScanner(r io.Reader) *lineScanner {
	return &lineScanner{br: bufio.NewReaderSize(r, 16*1024)}
}

// next returns the next non-blank line with the trailing line terminator
// removed. Blank lines are skipped, matching how Scanner.nextToken() handles
// empty tokens. The returned error is io.EOF at end of input, or
// errLineTooLong when the cap is exceeded.
func (s *lineScanner) next() (string, error) {
	for {
		line, err := s.readLine()
		if err != nil {
			return "", err
		}
		if line != "" {
			return line, nil
		}
	}
}

func (s *lineScanner) readLine() (string, error) {
	var buf []byte
	for {
		b, err := s.br.ReadByte()
		if err != nil {
			if err == io.EOF {
				if len(buf) > 0 {
					s.lineno++
					return string(buf), nil
				}
				return "", io.EOF
			}
			return "", err
		}
		if b == '\n' {
			s.lineno++
			return string(buf), nil
		}
		if b == '\r' {
			// Treat CR and CRLF as a terminator so files edited on Windows
			// still parse.
			if nxt, perr := s.br.Peek(1); perr == nil && nxt[0] == '\n' {
				_, _ = s.br.ReadByte()
			}
			s.lineno++
			return string(buf), nil
		}
		buf = append(buf, b)
		if utf8.RuneCount(buf) > MaxHeaderLineChars {
			return "", fmt.Errorf("%w: line %d exceeds %d characters",
				ErrInvalid, s.lineno+1, MaxHeaderLineChars)
		}
	}
}

// nextInt mirrors parseIntSafely(line, default) followed by the caller's
// "must parse" expectation: any failure invalidates the file.
func (s *lineScanner) nextInt(what string) (int, error) {
	line, err := s.next()
	if err != nil {
		return 0, fmt.Errorf("%w: cannot read %s: %v", ErrInvalid, what, err)
	}
	n, err := parseIntJava(line)
	if err != nil {
		return 0, fmt.Errorf("%w: bad %s %q", ErrInvalid, what, line)
	}
	return n, nil
}
