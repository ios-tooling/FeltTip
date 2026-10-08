import Testing
import Foundation
@testable import FeltTip

@Suite struct HighlightTests {
	@Test func basicHighlight() {
		let result = HighlightSyntax.process("Some ==highlighted== text")
		#expect(result == "Some <mark>highlighted</mark> text")
	}

	@Test func multipleHighlights() {
		let result = HighlightSyntax.process("==one== and ==two==")
		#expect(result.contains("<mark>one</mark>"))
		#expect(result.contains("<mark>two</mark>"))
	}

	@Test func noHighlight() {
		let result = HighlightSyntax.process("No highlights here")
		#expect(result == "No highlights here")
	}

	@Test func singleEquals() {
		let result = HighlightSyntax.process("a = b and c = d")
		#expect(result == "a = b and c = d")
	}

	@Test func highlightInParsedMarkdown() {
		let blocks = MarkdownBlockParser.parse("Hello ==world== there")
		guard case .paragraph(let content, _, _) = blocks.first else {
			Issue.record("Expected paragraph"); return
		}
		// The <mark> tag should set the highlight style on its run.
		#expect(content.runs.contains { $0.style.contains(.highlight) }, "Highlighted text should carry the highlight style")
	}

	@Test func highlightSurvivesHTMLRenderingForTheStyledPane() {
		let html = MarkdownHTMLRenderer.renderDocument(
			markdown: "Hello ==world==",
			includeSourceOffsets: true)
		#expect(html.contains("<span data-s=\"8\"><mark>world</mark></span>"))
	}
}
