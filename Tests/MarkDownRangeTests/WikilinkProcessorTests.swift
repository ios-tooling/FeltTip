import Testing
@testable import MarkDownRange

/// Wikilink preprocessor — Obsidian/Bear-style `[[Page]]` and
/// `[[Page|Alias]]` syntax desugared into markdown links with a
/// `wikilink://` URL scheme so the host can intercept them at click time.
@Suite struct WikilinkProcessorTests {
	@Test func basicWikilink_becomesLinkWithSchemeAndSamePageDisplay() {
		let result = WikilinkProcessor.process("See [[Home Page]] for details.")
		#expect(result == "See [Home Page](wikilink://Home%20Page) for details.")
	}

	@Test func aliasedWikilink_keepsDisplayAndUsesPageInURL() {
		// `|Alias` separates the URL target from the rendered text.
		let result = WikilinkProcessor.process("Read [[architecture|the architecture doc]] first.")
		#expect(result == "Read [the architecture doc](wikilink://architecture) first.")
	}

	@Test func noBrackets_passesThroughUntouched() {
		// Fast-path guard: input without `[[` must short-circuit.
		let input = "Plain prose with [a link](url) but no wikilinks."
		#expect(WikilinkProcessor.process(input) == input)
	}

	@Test func unclosedOpener_isLeftLiteral() {
		// `[[Page` without a closing `]]` is not a wikilink — keep the brackets.
		let result = WikilinkProcessor.process("Start [[Page but never closes.")
		#expect(result.contains("[[Page"))
		#expect(!result.contains("wikilink://"))
	}

	@Test func emptyBrackets_areNotConverted() {
		// `[[]]` has no page name; emit the brackets literally.
		let result = WikilinkProcessor.process("Empty [[]] does nothing.")
		#expect(!result.contains("wikilink://"))
	}

	@Test func multipleOnOneLine_allConvert() {
		let result = WikilinkProcessor.process("Jump to [[A]] or [[B]] or [[C|see C]].")
		#expect(result == "Jump to [A](wikilink://A) or [B](wikilink://B) or [see C](wikilink://C).")
	}

	@Test func newlineInsideBrackets_isNotAWikilink() {
		// Wikilinks are single-line; a `[[` paired with a `]]` across a line
		// break must stay literal so we don't swallow paragraph boundaries.
		let result = WikilinkProcessor.process("Start [[Page\nbody]] end.")
		#expect(result.contains("[[Page"))
		#expect(!result.contains("wikilink://"))
	}

	@Test func pageWithSpecialCharacters_isPercentEncoded() {
		// Page names with characters illegal in a URL path must be encoded so
		// the resulting `wikilink://...` is parseable as a URL.
		let result = WikilinkProcessor.process("[[Hello World & Friends]]")
		#expect(result.contains("wikilink://"))
		// The display text keeps the literal name; the URL portion is encoded.
		#expect(result.contains("[Hello World & Friends]"))
		#expect(!result.contains("wikilink://Hello World"))
	}
}
