import Testing
import Foundation
@testable import FeltTip

@Suite struct EntityReferenceTests {
	private func parseParagraphText(_ md: String) -> String {
		let blocks = MarkdownBlockParser.parse(md)
		guard case .paragraph(let content, _, _) = blocks.first else { return "" }
		return String(content.characters)
	}

	@Test func namedEntityAmp() {
		let text = parseParagraphText("Tom &amp; Jerry")
		#expect(text.contains("&"), "Entity &amp; should render as &")
	}

	@Test func namedEntityLt() {
		let text = parseParagraphText("a &lt; b")
		#expect(text.contains("<"), "Entity &lt; should render as <")
	}

	@Test func namedEntityGt() {
		let text = parseParagraphText("a &gt; b")
		#expect(text.contains(">"), "Entity &gt; should render as >")
	}

	@Test func numericDecimalEntity() {
		let text = parseParagraphText("&#169; 2026")
		#expect(text.contains("\u{00A9}"), "&#169; should render as copyright symbol")
	}

	@Test func numericHexEntity() {
		let text = parseParagraphText("&#x2764; love")
		#expect(text.contains("\u{2764}"), "&#x2764; should render as heart")
	}

	@Test func namedEntityNbsp() {
		let text = parseParagraphText("hello&nbsp;world")
		#expect(text.contains("hello") && text.contains("world"))
	}

	@Test func entityInLink() {
		let blocks = MarkdownBlockParser.parse("[R &amp; D](https://example.com)")
		guard case .paragraph(let content, let links, _) = blocks.first else {
			Issue.record("Expected paragraph"); return
		}
		let text = String(content.characters)
		#expect(text.contains("R & D"))
		#expect(links.count == 1)
	}
}
