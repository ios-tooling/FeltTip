import Testing
@testable import FeltTip

/// CommonMark 0.31.2 § 4.9 — Blank lines.
///
/// "Blank lines between block-level elements are ignored, except for the role
/// they play in determining whether a list is tight or loose. Blank lines at
/// the beginning and end of the document are also ignored."
///
/// Delegated to swift-markdown — these tests guard the integration.
@Suite struct BlankLineTests {
	@Test func multipleBlankLines_collapseBetweenParagraphs() {
		// Three paragraphs with varying gaps must still emit three paragraph blocks.
		let md = "First\n\nSecond\n\n\n\nThird"
		let blocks = MarkdownBlockParser.parse(md)
		let paragraphs = blocks.filter { if case .paragraph = $0 { return true }; return false }
		#expect(paragraphs.count == 3)
	}

	@Test func leadingBlankLines_ignored() {
		// Blank lines at the start of the document should not produce any block.
		let md = "\n\n\nFirst paragraph"
		let blocks = MarkdownBlockParser.parse(md)
		#expect(blocks.count == 1)
		guard case .paragraph(let content, _, _) = blocks.first else {
			Issue.record("Expected paragraph"); return
		}
		#expect(String(content.characters) == "First paragraph")
	}

	@Test func trailingBlankLines_ignored() {
		let md = "Only paragraph\n\n\n\n"
		let blocks = MarkdownBlockParser.parse(md)
		#expect(blocks.count == 1)
	}

	@Test func blankLine_separatesParagraphFromList() {
		// Without the blank line some parsers would attach the list to the
		// paragraph — CommonMark requires the gap to start a new block.
		let md = "Paragraph\n\n- item"
		let blocks = MarkdownBlockParser.parse(md)
		#expect(blocks.count == 2)
		if case .paragraph = blocks.first {} else { Issue.record("Expected paragraph first") }
		if case .unorderedList = blocks.last {} else { Issue.record("Expected list last") }
	}
}
