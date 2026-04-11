import Testing
import Foundation
@testable import MarkDownRange

@Suite struct ComplexDocumentTests {
	@Test func fullDocument() {
		let md = """
		# Project README

		This is a **complex** document with *many* features.

		## Features

		- Item one
		- Item two
		  - Sub-item
		- Item three

		## Code Example

		```swift
		func hello() {
		    print("Hello!")
		}
		```

		## Links

		Visit [our website](https://example.com) for more info.

		---

		> This is a blockquote with **bold** text.

		| Column A | Column B |
		|----------|----------|
		| Cell 1   | Cell 2   |

		1. First ordered
		2. Second ordered
		3. Third ordered
		"""
		let blocks = MarkdownBlockParser.parse(md)
		#expect(blocks.count >= 10, "Complex document should produce many blocks")

		let headings = blocks.filter { if case .heading = $0 { return true }; return false }
		#expect(headings.count >= 3)

		let lists = blocks.filter { b in
			if case .unorderedList = b { return true }
			if case .orderedList = b { return true }
			return false
		}
		#expect(lists.count >= 2)

		let codeBlocks = blocks.filter { if case .codeBlock = $0 { return true }; return false }
		#expect(codeBlocks.count == 1)

		let tables = blocks.filter { if case .table = $0 { return true }; return false }
		#expect(tables.count == 1)

		let breaks = blocks.filter { if case .thematicBreak = $0 { return true }; return false }
		#expect(breaks.count == 1)

		let quotes = blocks.filter { if case .blockquote = $0 { return true }; return false }
		#expect(quotes.count == 1)
	}

	@Test func blockIdsAreUnique() {
		let md = "# One\n\nPara\n\n## Two\n\nMore text\n\n- List\n\n```\ncode\n```"
		let blocks = MarkdownBlockParser.parse(md)
		let ids = blocks.map(\.id)
		#expect(Set(ids).count == ids.count, "All block IDs should be unique")
	}

	@Test func parsePerformanceSmallDoc() {
		let md = String(repeating: "Hello world. This is a sentence. ", count: 100)
		let blocks = MarkdownBlockParser.parse(md)
		#expect(!blocks.isEmpty)
	}

	@Test func parsePerformanceManyHeadings() {
		let md = (1...50).map { "## Heading \($0)\n\nParagraph \($0)\n" }.joined()
		let blocks = MarkdownBlockParser.parse(md)
		let headings = blocks.filter { if case .heading = $0 { return true }; return false }
		#expect(headings.count == 50)
	}

	@Test func unicodeContent() {
		let text = "日本語テスト **太字** and `コード`"
		let blocks = MarkdownBlockParser.parse(text)
		guard case .paragraph(let content, _, _) = blocks.first else { Issue.record("not para"); return }
		let str = String(content.characters)
		#expect(str.contains("日本語"))
		#expect(str.contains("太字"))
		#expect(str.contains("コード"))
	}

	@Test func emojiContent() {
		let blocks = MarkdownBlockParser.parse("# 🎉 Celebration\n\nHello 🌍 world 🚀")
		guard case .heading(_, let content, _) = blocks.first else { Issue.record("not heading"); return }
		#expect(String(content.characters).contains("🎉"))
	}

	@Test func veryLongLine() {
		let longWord = String(repeating: "a", count: 10000)
		let blocks = MarkdownBlockParser.parse(longWord)
		#expect(!blocks.isEmpty)
	}

	@Test func specialCharactersInCode() {
		let md = "```\n<script>alert('xss')</script>\n```"
		let blocks = MarkdownBlockParser.parse(md)
		guard case .codeBlock(let code, _, _) = blocks.first else { Issue.record("not code"); return }
		#expect(code.contains("<script>"), "Code blocks should preserve HTML-like content")
	}

	@Test func linkWithSpecialChars() {
		let blocks = MarkdownBlockParser.parse("[link](https://example.com/path?q=1&r=2#section)")
		guard case .paragraph(_, let links, _) = blocks.first else { Issue.record("not para"); return }
		#expect(links.first?.url.contains("q=1") == true)
	}
}
