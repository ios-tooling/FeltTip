//
//  MarkdownHTMLRendererTests.swift
//  FeltTipTests
//
//  Covers the HTML document renderer that the PDF/CLI path is built on.
//

import Testing
@testable import FeltTip

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
		// Code is syntax-highlighted server-side, so tokens are wrapped in
		// spans rather than emitted as one contiguous string.
		#expect(html.contains("<span class=\"tok-keyword\">let</span>"))
		#expect(html.contains("<span class=\"tok-number\">1</span>"))
		#expect(html.contains(" x = "))   // plain text passes through between spans
	}

	@Test func highlightsStringsAndComments() {
		let html = MarkdownHTMLRenderer.renderDocument(
			markdown: "```swift\n// note\nlet s = \"hi\"\n```", theme: .default)
		#expect(html.contains("<span class=\"tok-comment\">// note</span>"))
		#expect(html.contains("<span class=\"tok-string\">&quot;hi&quot;</span>"))
		#expect(html.contains(".tok-keyword"))   // the palette CSS is embedded
	}

	@Test func mermaidCodeKeepsRawSourceUnhighlighted() {
		let html = MarkdownHTMLRenderer.renderDocument(
			markdown: "```mermaid\ngraph TD\n  A --> B\n```", theme: .default)
		// Mermaid source must stay intact (a diagram engine consumes it), so it
		// is not tokenized/wrapped.
		#expect(html.contains("graph TD"))
		#expect(!html.contains("<span class=\"tok-"))
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

	@Test func rendersStrikethrough() {
		let html = MarkdownHTMLRenderer.renderDocument(markdown: "text ~~gone~~ here", theme: .default)
		#expect(html.contains("<del>gone</del>"))
	}

	@Test func rendersInlineMarkdownInsideDefinitionLists() {
		let html = MarkdownHTMLRenderer.renderBodyFragment(markdown: """
			Term
			: A definition with **strong**, _emphasis_, `code`, and [a link](https://example.com).
			""")

		#expect(html.contains("<dt>Term</dt>"))
		#expect(html.contains("<dd>A definition with <strong>strong</strong>, <em>emphasis</em>, <code>code</code>, and <a href=\"https://example.com\">a link</a>.</dd>"))
		#expect(!html.contains("**strong**"))
		#expect(!html.contains("_emphasis_"))
	}

	@Test func rendersFootnotesAsNavigableInPageAnchors() {
		let html = MarkdownHTMLRenderer.renderDocument(
			markdown: "See the note.[^release]\n\n[^release]: Deployment details.",
			theme: .default)
		#expect(html.contains("href=\"#feltip-footnote-release\" id=\"feltip-footnote-ref-release\""))
		#expect(html.contains("href=\"#feltip-footnote-ref-release\" id=\"feltip-footnote-release\""))
		#expect(html.contains("href=\"#feltip-footnote-ref-release\""))
		#expect(!html.contains("footnote://"))
		#expect(!html.contains("footnote-anchor://"))
		#expect(!html.contains("footnote-back://"))
	}

	@Test func blocksUnknownCustomLinkSchemes() {
		let html = MarkdownHTMLRenderer.renderDocument(
			markdown: "[unsafe](untrusted-scheme://payload)", theme: .default)
		#expect(html.contains("href=\"#\""))
		#expect(!html.contains("href=\"untrusted-scheme://payload\""))
	}

	@Test func imageRowsDoNotStretchBadgeImages() {
		let markdown = """
		[![GitHub release](https://img.shields.io/github/v/release/agalwood/Motrix.svg)](https://github.com/agalwood/Motrix/releases) ![Build/release](https://github.com/agalwood/Motrix/workflows/Build/release/badge.svg) ![Total Downloads](https://img.shields.io/github/downloads/agalwood/Motrix/total.svg)
		"""
		let html = MarkdownHTMLRenderer.renderDocument(markdown: markdown, theme: .default)
		#expect(html.contains("<div class=\"image-row\">"))
		#expect(html.contains("<a href=\"https://github.com/agalwood/Motrix/releases\"><img src=\"https://img.shields.io/github/v/release/agalwood/Motrix.svg\" alt=\"GitHub release\"></a>"))
		#expect(html.contains("<img src=\"https://github.com/agalwood/Motrix/workflows/Build/release/badge.svg\" alt=\"Build/release\">"))
		#expect(html.contains("<img src=\"https://img.shields.io/github/downloads/agalwood/Motrix/total.svg\" alt=\"Total Downloads\">"))
		#expect(html.contains("align-items: flex-start;"))
		#expect(html.contains(".image-row img,"))
		#expect(html.contains(".image-row a"))
		#expect(html.contains("flex: 0 0 auto;"))
	}
}
