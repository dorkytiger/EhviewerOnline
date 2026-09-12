package scan

import (
	"regexp"
	"strings"
	"unicode"
)

// DirTags is what a gallery directory name yields once the site's title
// convention is taken apart.
//
// The convention, as it appears in EH titles and therefore in the directory
// name EhViewer builds from them (FileUtils.sanitizeFilename only removes
// characters the filesystem rejects, it does not restructure anything):
//
//	[Circle (Artist)] Title (Parody) [Language] [Scanlation group] [Digital]
//
// Every field here is a heuristic over a string the site never promised to
// format consistently, and they exist to be filterable rather than to be
// authoritative. The parser resolves ambiguity in one direction only: when a
// group might or might not be metadata, it stays in Title. A marker left in a
// title costs a bracketed suffix, while a title fragment filed under the wrong
// dimension is wrong in the filter list with no way for the user to tell.
type DirTags struct {
	// Title is the display title with every group the convention identifies
	// removed. Empty when the name is nothing but groups, so the caller can
	// fall back to the raw string instead of showing a blank title.
	Title string

	// Artists are the leading "[...]" groups: the circle or artist.
	Artists []string

	// Groups are scanlation groups: trailing "[...]" groups that are not
	// markers. A scanlation group's name cannot be enumerated, so this
	// dimension is defined by exclusion — square brackets are where the
	// convention puts it, and every other use of the slot is a known word.
	Groups []string

	// Series are parenthesised groups that are neither an event code nor a
	// marker. The site reuses the same parentheses for parodies ("(Warzard)"),
	// source works ("(Pixiv Fanbox)") and editions, so this is the least
	// certain dimension of the five.
	Series []string

	// Events are leading "(...)" groups shaped like an event code: C85, FF35.
	Events []string

	// Editions are the marker groups: Digital, Complete, Uncensored.
	Editions []string
}

// eventCode matches the convention's event tags — Comiket's "C97", Comic
// Market's "FF35". Requiring digits is what separates them from a parody or a
// source work, which is the only reason a leading parenthesised group can be
// classified at all.
var eventCode = regexp.MustCompile(`^[A-Za-z]{1,5}[0-9]{1,3}$`)

// ParseDirTags splits a directory-derived title into its parts.
//
// The input is the title with the "<gid>-" prefix already removed, i.e. the
// second result of ParseDirName. Passing a whole directory name works too — it
// simply finds no groups before the gid — but the prefix then stays in Title.
func ParseDirTags(raw string) DirTags {
	tokens := tokenizeDirTitle(raw)

	// Position decides meaning: the convention opens with the artist and
	// closes with the markers, so a group before any text and a group after
	// all of it are read differently from one in the middle.
	firstText, lastText := len(tokens), -1
	for i, t := range tokens {
		if t.kind == tokText {
			if firstText == len(tokens) {
				firstText = i
			}
			lastText = i
		}
	}

	var (
		out       DirTags
		titlePart []string
	)
	for i, t := range tokens {
		if t.kind == tokText {
			titlePart = append(titlePart, t.text)
			continue
		}

		// Content is read before position: a known word means the same thing
		// wherever it appears, and a name can carry a marker in a slot the
		// convention does not put one in — "[Chinese] Title", "(Complete)
		// Title", or a name that is nothing but a marker, where there is no
		// position to read at all.
		words := markerWordsOf(t.text)
		switch {
		case words.isLanguage():
			// Deliberately dropped rather than filed as an edition:
			// SimpleLanguage already answers "what language is this" from the
			// same title, and two sources for one filter would disagree the
			// moment one of them changed.
		case words.isMarker():
			out.Editions = append(out.Editions, cleanGroupValue(t.text))
		case i > lastText:
			// The trailing slot: a bracket here is the scanlation group, and
			// anything else is a series. Note this branch also catches a name
			// with no text at all, where lastText is -1.
			if t.kind == tokBracket {
				out.Groups = append(out.Groups, cleanGroupValue(t.text))
			} else {
				out.Series = append(out.Series, cleanGroupValue(t.text))
			}
		case i < firstText:
			// The leading slot: an event code, else the circle/artist. A
			// parenthesised group that is neither is a series introduced
			// before the title, which the convention does produce.
			switch {
			case t.kind == tokParen && eventCode.MatchString(strings.TrimSpace(t.text)):
				out.Events = append(out.Events, cleanGroupValue(t.text))
			case t.kind == tokBracket:
				out.Artists = append(out.Artists, cleanGroupValue(t.text))
			default:
				out.Series = append(out.Series, cleanGroupValue(t.text))
			}
		default:
			// The middle: a bracket is still the artist, anything else is
			// still a series.
			if t.kind == tokBracket {
				out.Artists = append(out.Artists, cleanGroupValue(t.text))
			} else {
				out.Series = append(out.Series, cleanGroupValue(t.text))
			}
		}
	}

	// Removing a group leaves the spaces that surrounded it, and EH titles are
	// full of double spaces even before that.
	out.Title = strings.Join(strings.Fields(strings.Join(titlePart, " ")), " ")
	return out
}

type tokenKind int

const (
	tokText tokenKind = iota
	tokBracket
	tokParen
)

type dirToken struct {
	kind tokenKind
	// For a group this is the inner text, brackets already removed.
	text string
}

// tokenizeDirTitle splits a title into text runs and bracketed groups, in the
// order they appear.
//
// Nesting is tracked because the convention nests: "[Kemotsubo (Shintani)]"
// must close on the final ']', not on the ')' inside. A bracketed run that
// never closes, or that closes in the wrong order ("[a)b]"), is treated as
// plain text rather than guessed at, so a mangled name is left in the title
// instead of being cut in the wrong place.
func tokenizeDirTitle(s string) []dirToken {
	var (
		out []dirToken
		buf strings.Builder
	)
	flush := func() {
		if text := strings.TrimSpace(buf.String()); text != "" {
			out = append(out, dirToken{kind: tokText, text: text})
		}
		buf.Reset()
	}

	for i := 0; i < len(s); {
		c := s[i]
		if c != '[' && c != '(' {
			buf.WriteByte(c)
			i++
			continue
		}
		inner, end, ok := matchForward(s, i)
		if !ok {
			buf.WriteByte(c)
			i++
			continue
		}
		flush()
		kind := tokBracket
		if c == '(' {
			kind = tokParen
		}
		out = append(out, dirToken{kind: kind, text: inner})
		i = end
	}
	flush()
	return out
}

// matchForward finds the bracket closing the opener at s[start] and returns
// the text between them.
//
// A crossed pair ("[a)b]") is rejected rather than guessed at, so a mangled
// name is left alone instead of being cut in the wrong place.
func matchForward(s string, start int) (inner string, end int, ok bool) {
	var stack []byte
	for i := start; i < len(s); i++ {
		switch c := s[i]; c {
		case '[', '(':
			stack = append(stack, closerOf[c])
		case ']', ')':
			if len(stack) == 0 || stack[len(stack)-1] != c {
				return "", 0, false
			}
			if stack = stack[:len(stack)-1]; len(stack) == 0 {
				return s[start+1 : i], i + 1, true
			}
		}
	}
	return "", 0, false
}

var closerOf = map[byte]byte{'[': ']', '(': ')'}

// cleanGroupValue normalises a group's inner text for display.
//
// The site sometimes wraps a group in the other bracket kind — "((Teenage
// Mutant Ninja Turtles))" — which leaves a stray pair once the outer brackets
// are gone. One redundant layer is stripped so the facet reads as the name.
func cleanGroupValue(inner string) string {
	v := strings.Join(strings.Fields(inner), " ")
	for len(v) >= 2 {
		if v[0] != '(' || v[len(v)-1] != ')' {
			break
		}
		// Only strip when the outer '(' closes at the very end, so
		// "(a) (b)" is left alone.
		if _, end, ok := matchForward(v, 0); !ok || end != len(v) {
			break
		}
		v = strings.TrimSpace(v[1 : len(v)-1])
	}
	return v
}

// markerWords splits a group's inner text into comparable words and answers
// which marker vocabulary it belongs to.
type markerWords []string

func markerWordsOf(inner string) markerWords {
	return strings.FieldsFunc(strings.ToLower(inner), isMarkerSep)
}

// isMarkerSep splits on anything that is not a letter or a digit, so
// "(Chinese version)" and "(ESP-Latino)" are recognised word by word.
// CJK characters are letters, which keeps "中国翻訳" and "狗爹汉化组" whole —
// the latter must NOT match "汉化", and an exact-word test is what ensures it.
func isMarkerSep(r rune) bool {
	return !unicode.IsLetter(r) && !unicode.IsNumber(r)
}

func (w markerWords) isMarker() bool {
	for _, word := range w {
		if markerWordsAll[word] {
			return true
		}
	}
	return false
}

func (w markerWords) isLanguage() bool {
	for _, word := range w {
		if languageWords[word] {
			return true
		}
	}
	return false
}

// languageWords are the markers that only name a language. They are dropped
// rather than filed under Editions, because SimpleLanguage already answers
// "what language is this" from the same title and two sources for one filter
// would disagree the moment one of them changed.
var languageWords = map[string]bool{
	"chinese": true, "english": true, "japanese": true, "korean": true,
	"spanish": true, "espanol": true, "español": true, "french": true,
	"german": true, "italian": true, "portuguese": true, "russian": true,
	"thai": true, "vietnamese": true, "indonesian": true, "polish": true,
	"hungarian": true, "dutch": true, "turkish": true, "arabic": true,
	"czech": true, "greek": true, "swedish": true, "danish": true,
	"finnish": true, "norwegian": true, "ukrainian": true, "romanian": true,
	"catalan": true, "brazilian": true, "persian": true, "hindi": true,

	"中文": true, "汉化": true, "漢化": true, "翻译": true, "翻譯": true,
	"中国翻訳": true, "日本語": true, "한국어": true, "韓国翻訳": true,
}

// editionWords are the markers that describe the release rather than its
// language: how it was made, or what was done to it.
var editionWords = map[string]bool{
	"digital": true, "complete": true, "completed": true, "uncensored": true,
	"censored": true, "decensored": true, "raw": true, "sample": true,
	"mosaic": true, "translated": true, "translation": true, "version": true,
	"colorized": true, "decolorized": true, "無修正": true, "无修正": true,
	"重嵌": true,
}

// markerWordsAll is the union, used to decide whether a trailing group is
// metadata at all.
//
// The list is deliberately narrow. A word that could plausibly appear in a
// series name is left out even where it is sometimes a marker — "Full" and
// "Color" are the obvious casualties — because the cost of missing one is a
// bracketed suffix in a title, and the cost of a false positive is a piece of
// the title filed under Editions.
var markerWordsAll = func() map[string]bool {
	all := make(map[string]bool, len(languageWords)+len(editionWords))
	for w := range languageWords {
		all[w] = true
	}
	for w := range editionWords {
		all[w] = true
	}
	return all
}()
