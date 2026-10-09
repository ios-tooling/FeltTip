import Foundation
import Testing
@testable import FeltTip

@Suite struct OptimizationRegressionTests {
	@Test(arguments: [
		"- ```\n  ++literal++ [[Page]]\n  ```",
		"- ~~~\n  ++literal++ [[Page]]\n  ~~~",
		"1. ````swift\n   ++literal++ [[Page]]\n   ````",
		"> - ~~~\n>   ++literal++ [[Page]]\n>   ~~~",
		"- item\n  - ```\n    ++literal++ [[Page]]\n    ```",
		">     ++literal++ [[Page]]",
		"> >     ++literal++ [[Page]]",
		"- ~~~\r\n  ++literal++ [[Page]]\r\n  ~~~"
	]) func containerCodeRemainsVerbatim(source: String) {
		#expect(MarkdownPreprocessor.process(source) == source)
		#expect(MarkdownPreprocessor.processTrackingOffsets(source).processed == source)
	}

	@Test(arguments: ["- ```\n  ++inside++\n", "> - ~~~\n>   ++inside++\n"])
	func unclosedFenceEndsWithItsContainer(prefix: String) {
		let source = prefix + "\n++outside++"
		#expect(MarkdownPreprocessor.process(source) == prefix + "\n<u>outside</u>")
	}

	@Test(arguments: [false, true])
	func memoTracksDefinitionActivationAcrossBlankLines(offsets: Bool) {
		// A unique label isolates this cache sequence from parallel tests.
		let label = "reference-" + UUID().uuidString
		let definition = "[\(label)]: https://example.com"
		let active = "[\(label)]\n\n" + definition
		let fenced = "[\(label)]\n\n```\n\n" + definition + "\n\n```"
		func paragraph(_ source: String) -> String {
			MarkdownHTMLRenderer.renderBlockFragments(markdown: source, includeSourceOffsets: offsets).first!.html
		}
		#expect(!paragraph(fenced).contains("href="))
		#expect(paragraph(active).contains("href=\"https://example.com\""))
		#expect(!paragraph(fenced).contains("href="))
		#expect(paragraph(active).contains("href=\"https://example.com\""))
	}

	@Test(arguments: [false, true])
	func combiningMarkDoesNotShiftAutolink(offsets: Bool) {
		let html = MarkdownHTMLRenderer.renderBlockFragments(
			markdown: "<b>e</b>\u{301} https://example.com", includeSourceOffsets: offsets)
			.map(\.html).joined()
		#expect(html.contains(">https://example.com</a>"))
		#expect(!html.contains("> https://"))
	}

	@Test func graphemeOperationsCrossRunBoundaries() {
		let url = URL(string: "https://example.com")!
		var content = InlineContent(runs: [
			InlineRun("e", style: .bold, markdownSourceOffset: 3),
			InlineRun("\u{301} https://example.com", markdownSourceOffset: 8)
		])
		#expect(content.characterCount == content.characters.count)
		let applied = content.applyLink(url, characterRange: 2..<content.characterCount)
		#expect(applied)
		let linked = content.runs.filter { $0.link != nil }
		#expect(linked.map(\.text).joined() == "https://example.com")
		#expect(linked.first?.markdownSourceOffset == 10)
		content.removeFirst(characters: 1)
		#expect(content.characters == " https://example.com")
		#expect(content.runs.first?.markdownSourceOffset == 9)
	}

	@Test func linkCanCoverAClusterSpanningRuns() {
		var content = InlineContent(runs: [InlineRun("👩", style: .bold), InlineRun("\u{200D}💻 end")])
		let applied = content.applyLink(URL(string: "https://example.com")!, characterRange: 0..<1)
		#expect(applied)
		#expect(content.runs.filter { $0.link != nil }.map(\.text).joined() == "👩‍💻")
		content.removeFirst(characters: 1)
		#expect(content.characters == " end")
	}
}


extension OptimizationRegressionTests {
	@Test(arguments: [false, true])
	func memoDistinguishesReferenceExtentWithTheSameDestination(offsets: Bool) {
		let first = "first-" + UUID().uuidString
		let second = "second-" + UUID().uuidString
		let paragraph = "[\(first)][\(second)]\n\n"
		let a = "[\(first)]: https://example.com"
		let b = "[\(second)]: https://example.com"
		let fullReference = paragraph + "```\n\n" + a + "\n\n```\n\n" + b
		let shortcutReference = paragraph + a + "\n\n```\n\n" + b + "\n\n```"
		func render(_ source: String) -> String {
			MarkdownHTMLRenderer.renderBlockFragments(markdown: source, includeSourceOffsets: offsets).first!.html
		}
		#expect(!render(fullReference).contains("[\(second)]"))
		#expect(render(shortcutReference).contains("[\(second)]"))
		#expect(!render(fullReference).contains("[\(second)]"))
	}
}

extension OptimizationRegressionTests {
	@Test(arguments: [
		("plain paragraph", false),
		("text with a colon: here", false),
		("[id]: https://example.com", true),
		("intro\n\n> [id]: https://example.com\n", true)
	]) func memoContextReportsDefinitions(source: String, expected: Bool) {
		let context = InlineParagraphMemo.context(
			theme: .default, fontSize: 14, linkifyURLs: true, stamped: false, processedText: source)
		#expect(InlineParagraphMemo.hasDefinitions(context) == expected)
	}
}
