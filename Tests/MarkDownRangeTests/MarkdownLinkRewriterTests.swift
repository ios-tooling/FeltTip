//
//  MarkdownLinkRewriterTests.swift
//  MarkDownRangeTests
//

import Testing
@testable import MarkDownRange

@Suite struct MarkdownLinkRewriterTests {
	@Test func rewritesInlineLink() {
		let out = MarkdownLinkRewriter.replacingDestination(
			in: "see [docs](https://old.com) now",
			currentURL: "https://old.com", occurrence: 0, with: "https://new.com")
		#expect(out == "see [docs](https://new.com) now")
	}

	@Test func rewritesTheRequestedOccurrence() {
		let source = "[a](http://x) and [b](http://x)"
		#expect(MarkdownLinkRewriter.replacingDestination(in: source, currentURL: "http://x", occurrence: 1, with: "http://y")
			== "[a](http://x) and [b](http://y)")
	}

	@Test func leavesLinkWithTitleIntact() {
		let out = MarkdownLinkRewriter.replacingDestination(
			in: "[x](old.md \"title\")", currentURL: "old.md", occurrence: 0, with: "new.md")
		#expect(out == "[x](new.md \"title\")")
	}

	@Test func rewritesReferenceDefinition() {
		let out = MarkdownLinkRewriter.replacingDestination(
			in: "[x][1]\n\n[1]: https://old.com", currentURL: "https://old.com", occurrence: 0, with: "https://new.com")
		#expect(out == "[x][1]\n\n[1]: https://new.com")
	}

	@Test func returnsNilWhenNotFound() {
		#expect(MarkdownLinkRewriter.replacingDestination(in: "no links here", currentURL: "http://x", occurrence: 0, with: "http://y") == nil)
		// A bare mention of the URL in prose is not a destination context.
		#expect(MarkdownLinkRewriter.replacingDestination(in: "visit http://x today", currentURL: "http://x", occurrence: 0, with: "http://y") == nil)
	}
}
