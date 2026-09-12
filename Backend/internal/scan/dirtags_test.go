package scan

import (
	"reflect"
	"testing"
)

// TestParseDirTagsRealLibrary pins the parser against every directory name in
// a real synced library.
//
// These are not invented cases: the convention has more shapes than a
// hand-written table would think of — a parody in parentheses that must stay,
// an event code in the same position that must not, a scanlation group whose
// name contains a marker word — and each one of them broke an earlier draft of
// the rules. Keeping the real strings here is what stops the next change from
// quietly regressing them.
func TestParseDirTagsRealLibrary(t *testing.T) {
	cases := []struct {
		dir  string
		want DirTags
	}{
		{
			dir: "1080380-[balmos] 神龙大侠 (Kung Fu Panda) [黑曜石汉化组]",
			want: DirTags{
				Title:   "神龙大侠",
				Artists: []string{"balmos"},
				Series:  []string{"Kung Fu Panda"},
				Groups:  []string{"黑曜石汉化组"},
			},
		},
		{
			dir: "1260436-[Kemotsubo (Shintani)] LEO VS KUROMARU 3 (Chinese)",
			want: DirTags{
				Title:   "LEO VS KUROMARU 3",
				Artists: []string{"Kemotsubo (Shintani)"},
			},
		},
		{
			dir: "1279919-[Koukyuu Denim ni wa Shichimi o Kakenaide (Futee)] Exploitation [Chinese] [Digital]",
			want: DirTags{
				Title:    "Exploitation",
				Artists:  []string{"Koukyuu Denim ni wa Shichimi o Kakenaide (Futee)"},
				Editions: []string{"Digital"},
			},
		},
		{
			// No brackets at all: nothing to derive, and the title is the
			// whole name. Four galleries in this library look like this.
			dir:  "1280863-red earth leo comic",
			want: DirTags{Title: "red earth leo comic"},
		},
		{
			dir: "1453432-(C85) [Harugoya (Harusuke)] Harubon 11 [Chinese]",
			want: DirTags{
				Title:   "Harubon 11",
				Artists: []string{"Harugoya (Harusuke)"},
				Events:  []string{"C85"},
			},
		},
		{
			dir: "1548610-[Hyenaface] Breaking the King under the Mountain",
			want: DirTags{
				Title:   "Breaking the King under the Mountain",
				Artists: []string{"Hyenaface"},
			},
		},
		{
			// "狗爹汉化组" contains 汉化 but is not the word 汉化, so it must be
			// a group. An exact-word test is the only thing keeping it out of
			// Editions.
			dir: "1580288-[doggycoffee (Café au lait)] Shishi Ketsu Mikoto [Chinese] [狗爹汉化组] [Digital]",
			want: DirTags{
				Title:    "Shishi Ketsu Mikoto",
				Artists:  []string{"doggycoffee (Café au lait)"},
				Groups:   []string{"狗爹汉化组"},
				Editions: []string{"Digital"},
			},
		},
		{
			dir: "1594458-(FF35) [Raymond158] SINK INTO 2 [Chinese]",
			want: DirTags{
				Title:   "SINK INTO 2",
				Artists: []string{"Raymond158"},
				Events:  []string{"FF35"},
			},
		},
		{
			// "(Warzard)" sits between the title and the markers. It is a
			// parody, not a scanlation group, and treating every trailing
			// group as a group is exactly the bug this case caught.
			dir: "1642620-[Kemotsubo (Shintani)] Kuromaru Meikyuu Leo Hen 2 (Warzard) [Chinese] [Digital]",
			want: DirTags{
				Title:    "Kuromaru Meikyuu Leo Hen 2",
				Artists:  []string{"Kemotsubo (Shintani)"},
				Series:   []string{"Warzard"},
				Editions: []string{"Digital"},
			},
		},
		{
			dir: "1729233-[Grenade (Bomb)] Hadaka no Ou-sama (Warzard) [Chinese] [同文城]",
			want: DirTags{
				Title:   "Hadaka no Ou-sama",
				Artists: []string{"Grenade (Bomb)"},
				Series:  []string{"Warzard"},
				Groups:  []string{"同文城"},
			},
		},
		{
			dir:  "1822156-Uncle Rhino Who's Just Moved In Next Door",
			want: DirTags{Title: "Uncle Rhino Who's Just Moved In Next Door"},
		},
		{
			// Two spellings of one artist differing only in case exist in this
			// library. The parser keeps both verbatim; folding them together is
			// the index's job, because only the facet knows what a "same tag"
			// means for counting and display.
			dir: "1977506-[Koukyuu denim ni wa shichimi o kakenaide (futee)] PASSION Ookami Sousuke no Junan [Chinese] [Digital]",
			want: DirTags{
				Title:    "PASSION Ookami Sousuke no Junan",
				Artists:  []string{"Koukyuu denim ni wa shichimi o kakenaide (futee)"},
				Editions: []string{"Digital"},
			},
		},
		{
			dir: "2016306-[Renoky] 十二生肖 12 Zodiac Animals 2 [Chinese] [小紅個人漢化]",
			want: DirTags{
				Title:   "十二生肖 12 Zodiac Animals 2",
				Artists: []string{"Renoky"},
				Groups:  []string{"小紅個人漢化"},
			},
		},
		{
			dir: "2056534-[Denim ni Shichimi Kakenaide (Futee)] Tentacles [Chinese] [日曜日汉化组] [Digital]",
			want: DirTags{
				Title:    "Tentacles",
				Artists:  []string{"Denim ni Shichimi Kakenaide (Futee)"},
				Groups:   []string{"日曜日汉化组"},
				Editions: []string{"Digital"},
			},
		},
		{
			dir: "2098413-[Artdecade] Willy the Mook",
			want: DirTags{
				Title:   "Willy the Mook",
				Artists: []string{"Artdecade"},
			},
		},
		{
			dir:  "2173272-zhuye animation",
			want: DirTags{Title: "zhuye animation"},
		},
		{
			dir: "2184491-[Underground Campaign (Senga Migiri, jin)] Dokata Kuchiman Hole - Keibiin Hen",
			want: DirTags{
				Title:   "Dokata Kuchiman Hole - Keibiin Hen",
				Artists: []string{"Underground Campaign (Senga Migiri, jin)"},
			},
		},
		{
			// The site wrapped the parody in a second layer of the same
			// bracket. The outer pair is the group delimiter, so the leftover
			// pair is stripped: the facet should read as a name, not as
			// "(Teenage Mutant Ninja Turtles)".
			dir: "2201603-[Park Corner] Chained CH03 (Chinese version) ((Teenage Mutant Ninja Turtles))",
			want: DirTags{
				Title:   "Chained CH03",
				Artists: []string{"Park Corner"},
				Series:  []string{"Teenage Mutant Ninja Turtles"},
			},
		},
		{
			dir: "2221027-[Artdecade] Willy the Pooh",
			want: DirTags{
				Title:   "Willy the Pooh",
				Artists: []string{"Artdecade"},
			},
		},
		{
			// Double space in the source, and two adjacent groups with no
			// space between them.
			dir: "2234625-[18plusplus] Term 236-240 Defeated Warrior  战败勇者 [Chinese][猫咪自汉化]",
			want: DirTags{
				Title:   "Term 236-240 Defeated Warrior 战败勇者",
				Artists: []string{"18plusplus"},
				Groups:  []string{"猫咪自汉化"},
			},
		},
		{
			dir:  "2249230-DarkViperBara Argus Pack",
			want: DirTags{Title: "DarkViperBara Argus Pack"},
		},
		{
			dir: "2250733-[LionkinEn] Kuromaru x Equus (Chinese) (Complete)",
			want: DirTags{
				Title:    "Kuromaru x Equus",
				Artists:  []string{"LionkinEn"},
				Editions: []string{"Complete"},
			},
		},
		{
			dir: "2255922-[roaringmoon] Gun&Bullet 枪炮 (Pixiv Fanbox) [chinese]",
			want: DirTags{
				Title:   "Gun&Bullet 枪炮",
				Artists: []string{"roaringmoon"},
				Series:  []string{"Pixiv Fanbox"},
			},
		},
	}

	for _, c := range cases {
		t.Run(c.dir, func(t *testing.T) {
			_, title, ok := ParseDirName(c.dir)
			if !ok {
				t.Fatalf("ParseDirName(%q) did not match", c.dir)
			}
			got := ParseDirTags(title)
			if !equalDirTags(got, c.want) {
				t.Errorf("ParseDirTags(%q)\n got title=%q artists=%q groups=%q series=%q events=%q editions=%q\nwant title=%q artists=%q groups=%q series=%q events=%q editions=%q",
					title,
					got.Title, got.Artists, got.Groups, got.Series, got.Events, got.Editions,
					c.want.Title, c.want.Artists, c.want.Groups, c.want.Series, c.want.Events, c.want.Editions)
			}
		})
	}
}

func TestParseDirTagsEdges(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want DirTags
	}{
		{
			name: "empty stays empty",
			in:   "",
			want: DirTags{},
		},
		{
			name: "no groups is the title",
			in:   "plain title",
			want: DirTags{Title: "plain title"},
		},
		{
			// Nothing is left once the groups are removed, so Title is empty
			// and the caller keeps the raw string. Returning "[Digital]" as a
			// title would be worse than returning nothing.
			name: "only markers leaves no title",
			in:   "[Digital]",
			want: DirTags{Editions: []string{"Digital"}},
		},
		{
			name: "unclosed bracket is text",
			in:   "[unclosed title",
			want: DirTags{Title: "[unclosed title"},
		},
		{
			name: "crossed brackets are text",
			in:   "[a)b] title",
			want: DirTags{Title: "[a)b] title"},
		},
		{
			name: "nested brackets stay one group",
			in:   "[Circle (Artist)] The Title",
			want: DirTags{Title: "The Title", Artists: []string{"Circle (Artist)"}},
		},
		{
			name: "event code needs digits",
			in:   "(C85) Title",
			want: DirTags{Title: "Title", Events: []string{"C85"}},
		},
		{
			// A leading parenthesised group that is not an event code is read
			// as a series, not as an artist.
			name: "leading parody is a series",
			in:   "(Warzard) Title",
			want: DirTags{Title: "Title", Series: []string{"Warzard"}},
		},
		{
			name: "marker in the middle is an edition",
			in:   "Title (Complete) More",
			want: DirTags{Title: "Title More", Editions: []string{"Complete"}},
		},
		{
			name: "artist group in the middle",
			in:   "Title [Circle] More",
			want: DirTags{Title: "Title More", Artists: []string{"Circle"}},
		},
		{
			name: "language marker is dropped, not filed",
			in:   "Title [Chinese]",
			want: DirTags{Title: "Title"},
		},
		{
			name: "unknown bracket is a scanlation group",
			in:   "Title [Some Group]",
			want: DirTags{Title: "Title", Groups: []string{"Some Group"}},
		},
		{
			name: "leading and trailing groups together",
			in:   "[A] Title [B] [Chinese]",
			want: DirTags{Title: "Title", Artists: []string{"A"}, Groups: []string{"B"}},
		},
		{
			name: "whitespace is collapsed",
			in:   "  Title   With    Spaces  ",
			want: DirTags{Title: "Title With Spaces"},
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := ParseDirTags(c.in)
			if !equalDirTags(got, c.want) {
				t.Errorf("ParseDirTags(%q)\n got %+v\nwant %+v", c.in, got, c.want)
			}
		})
	}
}

func equalDirTags(a, b DirTags) bool {
	return a.Title == b.Title &&
		equalStrings(a.Artists, b.Artists) &&
		equalStrings(a.Groups, b.Groups) &&
		equalStrings(a.Series, b.Series) &&
		equalStrings(a.Events, b.Events) &&
		equalStrings(a.Editions, b.Editions)
}

// equalStrings treats nil and empty as equal, so a case can spell an
// expectation either way.
func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	if len(a) == 0 {
		return true
	}
	return reflect.DeepEqual(a, b)
}
