import Testing
import Foundation
@testable import FeltTip

@Suite struct InlineHTMLTests {
	private func parseParagraph(_ md: String) -> AttributedString? {
		let blocks = MarkdownBlockParser.parse(md)
		guard case .paragraph(let content, _, _) = blocks.first else { return nil }
		return content
	}

	@Test func lineBreak() {
		let attr = parseParagraph("Line one<br>Line two")
		let text = attr.map { String($0.characters) } ?? ""
		#expect(text.contains("\n"))
	}

	@Test func boldTag() {
		let attr = parseParagraph("Some <b>bold</b> text")
		#expect(attr != nil)
		// The attributed string should contain "bold" with a bold font
		let text = String(attr!.characters)
		#expect(text.contains("bold"))
	}

	@Test func superscriptTag() {
		let attr = parseParagraph("E = mc<sup>2</sup>")
		guard let attr else { Issue.record("nil"); return }
		let text = String(attr.characters)
		#expect(text.contains("2"))
		// Check baseline offset is set on the "2"
		var foundOffset = false
		for run in attr.runs {
			if String(attr.characters[run.range]).contains("2") {
				if let offset = run.baselineOffset, offset > 0 { foundOffset = true }
			}
		}
		#expect(foundOffset, "Superscript should have positive baseline offset")
	}

	@Test func subscriptTag() {
		let attr = parseParagraph("H<sub>2</sub>O")
		guard let attr else { Issue.record("nil"); return }
		var foundOffset = false
		for run in attr.runs {
			if String(attr.characters[run.range]).contains("2") {
				if let offset = run.baselineOffset, offset < 0 { foundOffset = true }
			}
		}
		#expect(foundOffset, "Subscript should have negative baseline offset")
	}

	@Test func underlineTag() {
		let attr = parseParagraph("Some <u>underlined</u> text")
		guard let attr else { Issue.record("nil"); return }
		var foundUnderline = false
		for run in attr.runs {
			if String(attr.characters[run.range]).contains("underline") {
				if run.underlineStyle != nil { foundUnderline = true }
			}
		}
		#expect(foundUnderline, "Underline should be applied")
	}

	@Test func underlineSurvivesHTMLRenderingForTheStyledPane() {
		let html = MarkdownHTMLRenderer.renderDocument(
			markdown: "Some <u>underlined</u> text",
			includeSourceOffsets: true)
		#expect(html.contains("<u>underlined</u>"))
	}

	@Test func unknownTagIgnored() {
		let attr = parseParagraph("Hello <unknown>world</unknown>")
		let text = attr.map { String($0.characters) } ?? ""
		#expect(text == "Hello world")
	}

	@Test func kbdTag() {
		let attr = parseParagraph("Press <kbd>Ctrl</kbd>+<kbd>C</kbd>")
		guard let attr else { Issue.record("nil"); return }
		let text = String(attr.characters)
		#expect(text.contains("Ctrl"))
		#expect(text.contains("C"))
	}
}
