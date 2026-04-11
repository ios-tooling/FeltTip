import Testing
@testable import MarkDownRange

@Suite struct ImageTests {
	@Test func soloImage() {
		let blocks = MarkdownBlockParser.parse("![Alt text](https://example.com/image.png)")
		guard case .image(let source, let alt, _) = blocks.first else {
			Issue.record("Expected image block, got \(blocks.first.debugDescription)"); return
		}
		#expect(source == "https://example.com/image.png")
		#expect(alt == "Alt text")
	}

	@Test func imageWithEmptyAlt() {
		let blocks = MarkdownBlockParser.parse("![](https://example.com/img.jpg)")
		guard case .image(let source, let alt, _) = blocks.first else {
			Issue.record("Expected image block"); return
		}
		#expect(source == "https://example.com/img.jpg")
		#expect(alt == "")
	}

	@Test func imageAmongText() {
		let md = "Before\n\n![photo](url)\n\nAfter"
		let blocks = MarkdownBlockParser.parse(md)
		let images = blocks.filter { if case .image = $0 { return true }; return false }
		#expect(images.count == 1)
	}

	@Test func inlineImageInParagraph() {
		let md = "Text with ![img](url) inline"
		let blocks = MarkdownBlockParser.parse(md)
		// Image should be extracted to its own block
		let images = blocks.filter { if case .image = $0 { return true }; return false }
		#expect(images.count == 1)
	}
}
