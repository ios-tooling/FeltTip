import Testing
import Foundation
@testable import MarkDownRange

@Suite struct MarkdownMetaTests {
	@Test func emptyText() {
		let meta = MarkdownMeta("")
		#expect(meta.wordCount == 0)
		#expect(meta.characterCount == 0)
		#expect(meta.headings.isEmpty)
		#expect(meta.links.isEmpty)
		#expect(meta.readingTime == "1 min read")
	}

	@Test func wordAndCharacterCounts() {
		let meta = MarkdownMeta("Hello world, this is **markdown**.")
		#expect(meta.wordCount == 5)
		#expect(meta.characterCount == 34)
		#expect(meta.lineCount == 1)
	}

	@Test func lineCountCountsNewlines() {
		let meta = MarkdownMeta("one\ntwo\nthree")
		#expect(meta.lineCount == 3)
	}

	@Test func streamingCountsPreserveUnicodeAndNewlineSemantics() {
		let meta = MarkdownMeta(text: " \t😀 café\r\nnext\u{2028}last \n", blocks: [])

		#expect(meta.wordCount == 4)
		#expect(meta.characterCount == 16)
		#expect(meta.lineCount == 4)
	}

	@Test func readingTimeScalesWithWords() {
		let short = MarkdownMeta(String(repeating: "word ", count: 50))
		#expect(short.readingTime == "1 min read")
		let long = MarkdownMeta(String(repeating: "word ", count: 600))
		#expect(long.readingTime == "3 min read")
	}

	@Test func collectsHeadings() {
		let meta = MarkdownMeta("# One\n\n## Two\n\n### Three")
		#expect(meta.headings.map(\.level) == [1, 2, 3])
		#expect(meta.headings.map(\.text) == ["One", "Two", "Three"])
	}

	@Test func collectsLinksFromParagraph() {
		let meta = MarkdownMeta("Visit [example](https://example.com) and [docs](https://docs.example.com).")
		#expect(meta.links.count == 2)
		#expect(meta.links.contains { $0.url == "https://example.com" && $0.text == "example" })
		#expect(meta.hasLinks)
	}

	@Test func collectsLinksInsideHeading() {
		let meta = MarkdownMeta("# See [here](https://here.test)")
		#expect(meta.links.first?.url == "https://here.test")
	}

	@Test func collectsLinksInsideListAndBlockquote() {
		let md = """
		- Item with [link](https://list.test)

		> Quoted [text](https://quote.test)
		"""
		let meta = MarkdownMeta(md)
		let urls = Set(meta.links.map(\.url))
		#expect(urls.contains("https://list.test"))
		#expect(urls.contains("https://quote.test"))
	}

	@Test func collectsImages() {
		let meta = MarkdownMeta("![alt text](img.png)")
		#expect(meta.images.count == 1)
		#expect(meta.images.first?.source == "img.png")
		#expect(meta.images.first?.alt == "alt text")
	}

	@Test func collectsCodeBlocksAndLanguages() {
		let md = """
		```swift
		let x = 1
		let y = 2
		```

		```
		plain
		```
		"""
		let meta = MarkdownMeta(md)
		#expect(meta.codeBlocks.count == 2)
		#expect(meta.codeBlockLanguages == ["swift"])
		#expect(meta.codeBlocks.first?.lineCount == 2)
	}

	@Test func collectsFrontmatter() {
		let meta = MarkdownMeta("---\ntitle: Hello\nauthor: Ben\n---\n\n# Body")
		#expect(meta.hasFrontmatter)
		#expect(meta.frontmatter.count == 2)
		#expect(meta.frontmatterValue(for: "title") == "Hello")
		#expect(meta.frontmatterValue(for: "author") == "Ben")
	}

	@Test func deduplicatesNothing() {
		let meta = MarkdownMeta("[a](https://x.test) and [a](https://x.test)")
		#expect(meta.links.count == 2, "Same URL appearing twice should be reported twice")
	}

	@Test func equatableSameInputProducesSameMeta() {
		let md = "# Hi\n\n[link](https://x.test)"
		#expect(MarkdownMeta(md) == MarkdownMeta(md))
	}
}
