import Testing
import Foundation
@testable import MarkDownRange

/// GFM § 6.9 — the "www." autolink extension. A run beginning at `www.`
/// followed by a valid domain becomes a link to `http://<run>`. These tests
/// guard the bits NSDataDetector doesn't already cover.
@Suite struct WWWAutolinkTests {
	private func parseLinks(_ md: String) -> [LinkInfo] {
		let blocks = MarkdownBlockParser.parse(md)
		guard case .paragraph(_, let links, _) = blocks.first else { return [] }
		return links
	}

	@Test func bareWWWURL_isLinked() {
		let links = parseLinks("Visit www.example.com today")
		#expect(links.count == 1)
		#expect(links.first?.url == "http://www.example.com")
	}

	@Test func wwwWithPath_isLinked() {
		let links = parseLinks("Read www.example.com/path/page.html now")
		#expect(links.first?.url == "http://www.example.com/path/page.html")
	}

	@Test func wwwRequiresAtLeastOneAdditionalDot() {
		// `www.foo` without a TLD is not a valid autolink — needs `www.x.y`.
		let links = parseLinks("Hello www.justonepart goodbye")
		#expect(links.isEmpty)
	}

	@Test func trailingPunctuation_isStripped() {
		// GFM rule: `?!.,:*_~` at the tail are not part of the URL.
		let links = parseLinks("Check www.example.com.")
		#expect(links.first?.url == "http://www.example.com")
	}

	@Test func trailingQuestionMark_isStripped() {
		let links = parseLinks("Is it www.example.com?")
		#expect(links.first?.url == "http://www.example.com")
	}

	@Test func unbalancedTrailingParen_isStripped() {
		// (see www.example.com) — the trailing `)` is not part of the URL
		// because there are more `)` than `(` in the candidate.
		let links = parseLinks("(see www.example.com)")
		#expect(links.first?.url == "http://www.example.com")
	}

	@Test func balancedTrailingParen_isKept() {
		// Wikipedia-style URLs have matched parens — those stay in the URL.
		let links = parseLinks("Read www.example.com/wiki/Topic_(disambiguation) now")
		#expect(links.first?.url == "http://www.example.com/wiki/Topic_(disambiguation)")
	}

	@Test func wwwInsideExplicitLink_isNotDoubleLinked() {
		// If the author already wrote `[label](http://www.example.com)`,
		// the linkify pass must not add a second link.
		let links = parseLinks("See [our site](http://www.example.com) please")
		#expect(links.count == 1)
		#expect(links.first?.url == "http://www.example.com")
	}

	@Test func multipleWWWURLsSameLine_allLinked() {
		let links = parseLinks("Either www.one.com or www.two.com work")
		#expect(links.count == 2)
		#expect(Set(links.map(\.url)) == ["http://www.one.com", "http://www.two.com"])
	}

	@Test func wwwInsideFencedCode_isNotLinked() {
		// Code blocks must round-trip verbatim — no link wrapping for `www.`
		// inside a fence.
		let md = """
		```
		www.example.com
		```
		"""
		let blocks = MarkdownBlockParser.parse(md)
		guard case .codeBlock(let code, _, _, _) = blocks.first else {
			Issue.record("Expected codeBlock, got \(blocks)"); return
		}
		#expect(code.contains("www.example.com"))
	}

	@Test func wwwInsideInlineCode_isNotLinked() {
		// Inline code-spans must also round-trip verbatim.
		let links = parseLinks("Use `www.example.com` in your config")
		#expect(links.isEmpty, "www. inside an inline code span should not be auto-linked")
	}

	@Test func wwwPrecededByLetter_isNotLinked() {
		// `xwww.example.com` shouldn't trigger — `\b` word boundary before
		// `www` requires the preceding char (if any) to be non-word.
		let links = parseLinks("Random xwww.example.com noise")
		#expect(links.isEmpty)
	}

	@Test func wwwIsCaseInsensitive() {
		// `WWW.` (uppercase) also counts.
		let links = parseLinks("Visit WWW.example.com today")
		#expect(links.count == 1)
		#expect(links.first?.url.lowercased() == "http://www.example.com")
	}
}
