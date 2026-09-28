import Testing
import Foundation
@testable import FeltTip

@Suite struct ParagraphTests {
	private func parseText(_ md: String) -> String {
		let blocks = MarkdownBlockParser.parse(md)
		guard case .paragraph(let content, _, _) = blocks.first else { return "" }
		return String(content.characters)
	}

	@Test func simpleParagraph() {
		#expect(parseText("Hello world") == "Hello world")
	}

	@Test func multipleParagraphs() {
		let blocks = MarkdownBlockParser.parse("Para one\n\nPara two\n\nPara three")
		let paras = blocks.filter { if case .paragraph = $0 { return true }; return false }
		#expect(paras.count == 3)
	}

	@Test func softBreakBecomesSpace() {
		let text = parseText("Line one\nLine two")
		#expect(text == "Line one Line two")
	}

	@Test func hardBreak() {
		let text = parseText("Line one  \nLine two")
		#expect(text.contains("\n"))
	}

	@Test func boldText() {
		#expect(parseText("Some **bold** text").contains("bold"))
	}

	@Test func italicText() {
		#expect(parseText("Some *italic* text").contains("italic"))
	}

	@Test func boldItalic() {
		#expect(parseText("Some ***bold italic*** text").contains("bold italic"))
	}

	@Test func strikethrough() {
		let blocks = MarkdownBlockParser.parse("Some ~~deleted~~ text")
		guard case .paragraph(let content, _, _) = blocks.first else { Issue.record("not para"); return }
		var foundStrike = false
		for run in content.runs {
			if run.strikethroughStyle != nil { foundStrike = true }
		}
		#expect(foundStrike)
	}

	@Test func inlineCode() {
		let text = parseText("Use `print()` here")
		#expect(text.contains("print()"))
	}

	@Test func linkInParagraph() {
		let blocks = MarkdownBlockParser.parse("Click [here](https://example.com)")
		guard case .paragraph(let content, let links, _) = blocks.first else { Issue.record("not para"); return }
		#expect(String(content.characters).contains("here"))
		#expect(links.count == 1)
		#expect(links.first?.url == "https://example.com")
	}

	@Test func multipleLinksSameLineParagraph() {
		let blocks = MarkdownBlockParser.parse("[A](https://a.com) and [B](https://b.com) and [C](https://c.com)")
		guard case .paragraph(_, let links, _) = blocks.first else { Issue.record("not para"); return }
		#expect(links.count == 3)
	}

	@Test func emptyDocument() {
		let blocks = MarkdownBlockParser.parse("")
		#expect(blocks.isEmpty)
	}

	@Test func whitespaceOnlyDocument() {
		let blocks = MarkdownBlockParser.parse("   \n\n   \n")
		#expect(blocks.isEmpty)
	}
}
