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
