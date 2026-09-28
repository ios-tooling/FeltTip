import Testing
@testable import FeltTip

/// CommonMark 0.31.2 § 2.2 — Tabs.
///
/// "Tabs in lines are not expanded to spaces. However, in contexts where
/// whitespace helps to define block structure, tabs behave as if they were
/// replaced by spaces with a tab stop of 4 characters."
///
/// Delegated to swift-markdown — these tests guard the integration.
@Suite struct TabExpansionTests {
	@Test func leadingTab_indentsToCodeBlock() {
		// One leading tab counts as 4 columns, which is the indented-code threshold.
		let blocks = MarkdownBlockParser.parse("Para\n\n\tcode\n\nEnd")
		let isCode = blocks.contains { if case .codeBlock = $0 { return true }; return false }
		#expect(isCode)
	}

	@Test func tabAfterListMarker_startsListContent() {
		// `- \tfoo` should still parse as a list item with "foo" as content,
		// not as something where the tab leaks into the content as a literal tab.
		let blocks = MarkdownBlockParser.parse("-\tfoo")
		guard case .unorderedList(let items, _) = blocks.first else {
			Issue.record("Expected unordered list, got \(blocks)"); return
		}
		#expect(items.count == 1)
	}

	@Test func tabInMiddleOfText_staysAsLiteralWhitespace() {
		// Tabs that aren't structural just appear in the text content.
		let blocks = MarkdownBlockParser.parse("foo\tbar")
		guard case .paragraph(let content, _, _) = blocks.first else {
			Issue.record("Expected paragraph"); return
		}
		let text = String(content.characters)
		#expect(text.contains("foo"))
		#expect(text.contains("bar"))
	}

	@Test func mixedTabsAndSpaces_inListNesting() {
		// Tab-indented continuation under a list item should still parse as
		// part of the same list, not as an indented code block.
		let md = "- item one\n\tstill item one\n- item two"
		let blocks = MarkdownBlockParser.parse(md)
		guard case .unorderedList(let items, _) = blocks.first else {
			Issue.record("Expected unordered list, got \(blocks)"); return
		}
		#expect(items.count == 2)
	}
}
