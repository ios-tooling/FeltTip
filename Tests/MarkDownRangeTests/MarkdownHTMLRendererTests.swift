//
//  MarkdownHTMLRendererTests.swift
//  MarkDownRangeTests
//
//  Covers the HTML document renderer that the PDF/CLI path is built on.
//

import Testing
@testable import MarkDownRange

@Suite struct MarkdownHTMLRendererTests {
	@Test func emitsStandaloneDocumentScaffold() {
		let html = MarkdownHTMLRenderer.renderDocument(markdown: "# Title", theme: .default)
		#expect(html.contains("<!DOCTYPE html>"))
		#expect(html.contains("<style>"))   // CSS is embedded for a self-contained doc
		#expect(html.contains("</html>"))
	}

	@Test func rendersHeadings() {
		let html = MarkdownHTMLRenderer.renderDocument(markdown: "# Hello", theme: .default)
		#expect(html.contains("<h1>"))
		#expect(html.contains("Hello"))
	}

	@Test func rendersFencedCode() {
		let html = MarkdownHTMLRenderer.renderDocument(markdown: "```swift\nlet x = 1\n```", theme: .default)
		#expect(html.contains("<pre"))
		#expect(html.contains("let x = 1"))
	}

	@Test func rendersTables() {
		let md = "| A | B |\n|---|---|\n| 1 | 2 |"
		let html = MarkdownHTMLRenderer.renderDocument(markdown: md, theme: .default)
		#expect(html.contains("<table"))
		#expect(html.contains("<td"))
	}

	@Test func rendersUnorderedLists() {
		let html = MarkdownHTMLRenderer.renderDocument(markdown: "- one\n- two", theme: .default)
		#expect(html.contains("<ul>"))
		#expect(html.contains("<li>"))
		#expect(html.contains("one"))
	}

	@Test func rendersInlineEmphasisAndLinks() {
		let html = MarkdownHTMLRenderer.renderDocument(markdown: "text **bold** and [link](https://example.com)", theme: .default)
		#expect(html.contains("<strong>"))
		#expect(html.contains("href=\"https://example.com\""))
	}
}
