package index

import "regexp"

// langPatterns is a direct port of GalleryInfo.S_LANG_PATTERNS
// (app/src/main/java/com/hippo/ehviewer/client/data/GalleryInfo.java:72-88),
// index-aligned with models.SLangCodes.
//
// These exist because SIMPLE_LANGUAGE in the exported DB is derived from
// simpleTags on the phone, and Gallery_Tags is NOT part of the export
// (EhDB.exportDB copies only eight tables; see the design doc §2.5). That
// column is therefore frequently NULL, and the title is the only remaining
// signal.
//
// The Java patterns were translated as literally as the Go regexp syntax
// allows. The notable differences from the Java source are cosmetic:
//
//   - Java writes the "misc" pattern alternation as-is; Go's regexp is RE2, so
//     backtracking-dependent constructs would behave differently. None of
//     these patterns contain such constructs.
//   - Unicode script/block escapes (\p{...}) are not used by the original.
//
// Order is significant and must not be reordered: the first match wins.
var langPatterns = []*regexp.Regexp{
	// EN
	regexp.MustCompile(`(?i)[(\[]eng(?:lish)?[)\]]|英訳`),
	// ZH
	regexp.MustCompile(`(?i)[(（\[]ch(?:inese)?[)）\]]|[汉漢]化|中[国國][语語]|中文|中国翻訳`),
	// ES
	regexp.MustCompile(`(?i)[(\[]spanish[)\]]|[(\[]Español[)\]]|スペイン翻訳`),
	// KO
	regexp.MustCompile(`(?i)[(\[]korean?[)\]]|韓国翻訳`),
	// RU
	regexp.MustCompile(`(?i)[(\[]rus(?:sian)?[)\]]|ロシア翻訳`),
	// FR
	regexp.MustCompile(`(?i)[(\[]fr(?:ench)?[)\]]|フランス翻訳`),
	// PT
	regexp.MustCompile(`(?i)[(\[]portuguese|ポルトガル翻訳`),
	// TH
	regexp.MustCompile(`(?i)[(\[]thai(?: ภาษาไทย)?[)\]]|แปลไทย|タイ翻訳`),
	// DE
	regexp.MustCompile(`(?i)[(\[]german[)\]]|ドイツ翻訳`),
	// IT
	regexp.MustCompile(`(?i)[(\[]italiano?[)\]]|イタリア翻訳`),
	// VI
	regexp.MustCompile(`(?i)[(\[]vietnamese(?: Tiếng Việt)?[)\]]|ベトナム翻訳`),
	// PL
	regexp.MustCompile(`(?i)[(\[]polish[)\]]|ポーランド翻訳`),
	// HU
	regexp.MustCompile(`(?i)[(\[]hun(?:garian)?[)\]]|ハンガリー翻訳`),
	// NL
	regexp.MustCompile(`(?i)[(\[]dutch[)\]]|オランダ翻訳`),
}
