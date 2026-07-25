//
//  HardBreakRenderingTests.swift
//  MarkDownRangeTests
//
//  A markdown hard break has to become a <br>. Emitted as a bare newline it
//  collapsed to a space in HTML, so `line one\` + newline rendered as one long
//  line in the styled view (and in exported HTML) while the NSTextView path
//  showed the break correctly.
//

import Foundation
import Testing
@testable import MarkDownRange

@Suite struct HardBreakRenderingTests {
	@Test func backslashBreakRendersAsABreakElement() {
		let html = MarkdownHTMLRenderer.renderBodyFragment(markdown: "one\\\ntwo")
		#expect(html.contains("<br>"))
		#expect(!html.contains("one\ntwo"))
	}

	@Test func trailingSpaceBreakRendersAsABreakElement() {
		let html = MarkdownHTMLRenderer.renderBodyFragment(markdown: "one  \ntwo")
		#expect(html.contains("<br>"))
	}

	@Test func aSoftBreakStaysASpace() {
		// A single newline is not a break in markdown; it must not become <br>.
		let html = MarkdownHTMLRenderer.renderBodyFragment(markdown: "one\ntwo")
		#expect(!html.contains("<br>"))
		#expect(html.contains("one"))
		#expect(html.contains("two"))
	}

	@Test func breaksDoNotDisturbSourceStamps() {
		// The break is its own unstamped run, so both neighbours keep stamps
		// that address their own first character.
		let source = "one\\\ntwo"
		let html = MarkdownHTMLRenderer.renderBodyFragment(markdown: source, includeSourceOffsets: true)
		#expect(html.contains("data-s=\"0\""))
		#expect(html.contains("data-s=\"5\""))
		let ns = source as NSString
		#expect(ns.substring(with: NSRange(location: 5, length: 3)) == "two")
	}

	@Test func multipleBreaksInOneParagraphAllRender() {
		let html = MarkdownHTMLRenderer.renderBodyFragment(markdown: "one\\\ntwo\\\nthree")
		#expect(html.components(separatedBy: "<br>").count - 1 == 2)
	}

	@Test func aBreakInsideEmphasisStaysInsideTheEmphasis() {
		let html = MarkdownHTMLRenderer.renderBodyFragment(markdown: "*one\\\ntwo*")
		#expect(html.contains("<br>"))
		#expect(html.contains("<em>"))
	}

	@Test func fragmentsAndWholeBodyAgreeAboutBreaks() {
		let markdown = "one\\\ntwo\n\nplain\n"
		let fragments = MarkdownHTMLRenderer.renderBlockFragments(markdown: markdown, includeSourceOffsets: true)
		#expect(fragments.map(\.html).joined()
			== MarkdownHTMLRenderer.renderBodyFragment(markdown: markdown, includeSourceOffsets: true))
	}

	@Test func codeBlocksKeepTheirLiteralNewlines() {
		// `pre` content is not inline-rendered, so its newlines must survive as
		// newlines (the CSS renders them with pre-wrap).
		let html = MarkdownHTMLRenderer.renderBodyFragment(markdown: "```\nlet a = 1\nlet b = 2\n```\n")
		#expect(html.contains("<pre>"))
		#expect(html.contains("\n"))          // the line break between the two lines
		#expect(!html.contains("<br>"))       // and not turned into an element
	}
}
