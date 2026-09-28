import Testing
@testable import FeltTip

/// CommonMark 0.31.2 § 2.4 — Backslash escapes.
///
/// Any ASCII punctuation character may be escaped with a backslash, in which
/// case it loses its markdown meaning and appears as a literal. Backslashes
/// before non-punctuation characters are not escapes and stay literal.
/// Delegated to swift-markdown, so these tests guard the integration, not the
/// rule itself.
@Suite struct BackslashEscapesTests {
	private func paragraphText(_ md: String) -> String {
		let blocks = MarkdownBlockParser.parse(md)
		guard case .paragraph(let content, _, _) = blocks.first else { return "" }
		return String(content.characters)
	}

	@Test func escapedAsterisk_doesNotStartEmphasis() {
		// Without escape, `*foo*` would become italic. With escape, it's literal.
		#expect(paragraphText(#"\*foo\*"#) == "*foo*")
	}

	@Test func escapedUnderscore_doesNotStartEmphasis() {
		#expect(paragraphText(#"\_foo\_"#) == "_foo_")
	}

	@Test func escapedBracket_doesNotStartLink() {
		// Without escape, `[x](y)` would be a link. With escape, it's literal.
		let text = paragraphText(#"\[not a link\](url)"#)
		#expect(text.contains("[not a link]"))
	}

	@Test func escapedBacktick_doesNotStartCodeSpan() {
		#expect(paragraphText(#"\`foo\`"#) == "`foo`")
	}

	@Test func escapedBackslash_appearsAsSingleBackslash() {
		#expect(paragraphText(#"\\"#) == #"\"#)
	}

	@Test func backslashBeforeLetter_isLiteral() {
		// CommonMark: backslash before non-punctuation is *not* an escape.
		// Both characters must survive verbatim.
		#expect(paragraphText(#"\A"#) == #"\A"#)
	}

	@Test func escapeInsideCodeSpan_isLiteral() {
		// Inside a code span, escapes are not processed — the backslash stays.
		let text = paragraphText("`\\*foo\\*`")
		#expect(text.contains(#"\*foo\*"#))
	}
}
