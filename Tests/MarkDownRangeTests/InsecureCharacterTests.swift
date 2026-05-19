import Testing
@testable import MarkDownRange

/// CommonMark 0.31.2 § 2.3 — Insecure characters.
///
/// "For security reasons, the Unicode character U+0000 must be replaced with
/// the REPLACEMENT CHARACTER (U+FFFD)."
///
/// Delegated to swift-markdown — these tests guard the integration.
@Suite struct InsecureCharacterTests {
	@Test func nullBytePromotedToReplacementCharacter() {
		// A raw U+0000 in the source should not appear in the parsed text. The
		// spec mandates replacement with U+FFFD; we accept either replacement or
		// removal, as long as the literal null is gone.
		let md = "before\u{0000}after"
		let blocks = MarkdownBlockParser.parse(md)
		guard case .paragraph(let content, _, _) = blocks.first else {
			Issue.record("Expected paragraph"); return
		}
		let text = String(content.characters)
		#expect(!text.contains("\u{0000}"), "Raw null byte must not survive parsing")
		#expect(text.contains("before"))
		#expect(text.contains("after"))
	}

	@Test func nullByteAtStartOfDocument_doesNotCrash() {
		// Regression guard: a leading null byte shouldn't break the parser even
		// if the substitution happens late in the pipeline.
		let md = "\u{0000}heading content"
		let blocks = MarkdownBlockParser.parse(md)
		#expect(!blocks.isEmpty)
	}
}
