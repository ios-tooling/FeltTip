import Foundation
import Testing
@testable import FeltTip

@Suite struct SecondPassRegressionTests {
	@Test func lazyContinuationInlineCodeBeforeFenceDoesNotCrash() {
		let source = "- item\n`a`\n```\ncode\n```\n"
		#expect(MarkdownPreprocessor.process(source) == source)
	}
	@Test(arguments: [
		"around ~60 times. use `x` to update ~30 times.",
		"a ++ `x` ++ b",
		"a ^2 `x` ^3 b",
	]) func markersDoNotPairAcrossInlineCode(source: String) {
		#expect(MarkdownPreprocessor.process(source) == source)
	}
	@Test func lazyContinuationMultilineSpanStaysProtected() {
		let source = "* e.g. `[['a',\n  'b'], ['c', 'd']]` turns into `('a', 'b')`\n"
		#expect(MarkdownPreprocessor.process(source) == source)
	}
	@Test func imageDestinationsCanBeRewritten() {
		let rewritten = MarkdownLinkRewriter.replacingDestination(
			in: "![a](http://x/1.png)", currentURL: "http://x/1.png", occurrence: 0, with: "http://y/1.png")
		#expect(rewritten == "![a](http://y/1.png)")
	}
	@Test func inlineCodeOnLazyContinuationStaysProtected() {
		let source = "- item\nuse `[[Page]]` here\n"
		#expect(MarkdownPreprocessor.process(source) == source)
	}
	@Test func paddedAndMultilineSpansStayProtected() {
		let source = "a `` `x` `` b\n\nc `one\n[[two]]` d\n"
		#expect(MarkdownPreprocessor.process(source) == source)
	}
	@Test func headingScansAgreeWithParse() {
		let sources = [
			"# One\r\n\r\nbody\r\n\r\n## Two\r\ntext",
			"~~~\n# Example\n~~~\n\n# Real",
			"````\n```\n# Example\n```\n````\n\n# Real",
			"    # Example\n\n# Real",
			"> ```\n> # Quoted\n> ```\n\n# Real",
			"- item\n\n    # In list\n\ntext\n\n    # code",
			"```swift\n# no\n```\n# After unclosed\n```\n# inside",
		]
		for source in sources {
			let parsed = MarkdownHeading.parse(from: source)
			for heading in parsed {
				#expect(MarkdownHeading.characterRange(for: heading.id, in: source) == heading.sourceRange, "\(source)")
				#expect(MarkdownHeading.heading(atCharacterOffset: heading.sourceRange.location, in: source)?.id == heading.id, "\(source)")
			}
			#expect(MarkdownHeading.heading(atCharacterOffset: (source as NSString).length, in: source)?.id == parsed.last?.id, "\(source)")
		}
	}
	@Test func unquotedApostropheDoesNotHideLaterStamps() {
		let html = "<p><span title=it's data-s=\"3\">a</span> <span data-s=\"9\">b</span></p>"
		#expect(MarkdownBlockFragment.firstStamp(in: html) == 3)
		#expect(MarkdownBlockFragment.shiftingStamps(in: html, by: 10).contains("data-s=\"19\""))
	}
}

@Suite struct CodeRegionScannerTests {
	private func ranges(_ source: String, blocksOnly: Bool = false) -> [String] {
		MarkdownCodeProtection.ranges(in: source, blocksOnly: blocksOnly).map { (source as NSString).substring(with: $0) }
	}
	@Test func fencesCloseOnlyOnMatchingRuns() {
		#expect(ranges("````\n```\nx\n```\n````\n") == ["````\n```\nx\n```\n````"])
		#expect(ranges("~~~\n```\nx\n~~~\n") == ["~~~\n```\nx\n~~~"])
		// A backtick in the info string makes this a paragraph line; the
		// later fence still interrupts that paragraph.
		#expect(ranges("```js `a`\nx\n```\n") == ["`a`", "```\n"])
		#expect(ranges("~~~ `a`\nx\n~~~\n") == ["~~~ `a`\nx\n~~~"])
		#expect(ranges("```\nunterminated\n") == ["```\nunterminated\n"])
	}
	@Test func containersBoundFences() {
		#expect(ranges("> ```\n> a\n> ```\n\n`b`") == ["```\n> a\n> ```", "`b`"])
		#expect(ranges("> ```\n> a\n\nafter `b`") == ["```\n> a", "`b`"])
		#expect(ranges("- item\n\n    ```\n    a\n    ```\n") == ["```\n    a\n    ```"])
		#expect(ranges("- item\n\n      code\n\ntext") == ["code"])
	}
	@Test func indentedCodeNeedsABlockBoundary() {
		#expect(ranges("para\n    continued\n") == [])
		#expect(ranges("# Heading\n    code\n") == ["code"])
		#expect(ranges("para\n\n    one\n\n    two\ntext") == ["one\n\n    two"])
		#expect(ranges("\tcode\n") == ["code"])
	}
	@Test func htmlBlocksHoldLiteralBackticks() {
		#expect(ranges("<div>\n`a`\n</div>\n\n`b`") == ["`b`"])
		#expect(ranges("<pre>\n`a`\n\n`still`\n</pre>\n`b`") == ["`b`"])
		#expect(ranges("<!-- `a`\n\n`b` -->\n`c`") == ["`c`"])
		#expect(ranges("<custom>\n`a`\n\n`b`") == ["`b`"])
		#expect(ranges("text\n<custom>\n`a`") == ["`a`"])
	}
	@Test func spansFollowCommonMarkPairing() {
		#expect(ranges("``a ` b`` and `c`") == ["``a ` b``", "`c`"])
		#expect(ranges("`first closes `here` not") == ["`first closes `"])
		#expect(ranges("\\`a `b`") == ["`b`"])
		#expect(ranges("`a\nb` c") == ["`a\nb`"])
		#expect(ranges("`a\n\nb `c`") == ["`c`"])
		#expect(ranges("# `h`\n`p`") == ["`h`", "`p`"])
		#expect(ranges("- `a\n  b`\n- `c`") == ["`a\n  b`", "`c`"])
	}
	@Test func tablesScanEachCell() {
		#expect(ranges("| a | b |\n|---|---|\n| x`s | y |\n| `c` | z` |") == ["`c`"])
		#expect(ranges("a | b\n--- | ---\n`x | y`") == [])
		#expect(ranges("| h |\n|---|\n| `a\\|b` |") == ["`a\\|b`"])
	}
	@Test func setextHeadingsAndQuotedListsBoundCode() {
		#expect(ranges("Title\n------\n    code\n") == ["code"])
		#expect(ranges("- item\n    > quoted\n\n    *not code*\n") == [])
		#expect(ranges("- item\n\n  > ```\n  > a\n  > ```\n") == ["```\n  > a\n  > ```"])
	}
	@Test func blocksOnlySkipsSpans() {
		#expect(ranges("`a`\n\n```\nb\n```", blocksOnly: true) == ["```\nb\n```"])
	}
}
