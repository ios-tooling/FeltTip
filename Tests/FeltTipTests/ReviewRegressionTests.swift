import Foundation
import Testing
import WebKit
@testable import FeltTip

@Suite(.serialized) @MainActor
struct ReviewRegressionTests {
	@Test(arguments: [false, true]) func multilineReferenceCache(stamped: Bool) {
		let first = "[label][dest]\n\n[dest]:\n  https://one.example\n"
		let second = "[label][dest]\n\n[dest]:\n  https://two.example\n"
		let initial = MarkdownHTMLRenderer.renderBodyFragment(markdown: first, includeSourceOffsets: stamped)
		let cached = MarkdownHTMLRenderer.renderBodyFragment(markdown: second, includeSourceOffsets: stamped)
		#expect(initial.contains("https://one.example"))
		#expect(cached.contains("https://two.example"))
	}
	@Test(arguments: [false, true]) func nestedReferenceCache(stamped: Bool) {
		let first = "[label][dest]\n\n> [dest]: https://one.example\n"
		let second = "[label][dest]\n\n> [dest]: https://two.example\n"
		let initial = MarkdownHTMLRenderer.renderBodyFragment(markdown: first, includeSourceOffsets: stamped)
		let cached = MarkdownHTMLRenderer.renderBodyFragment(markdown: second, includeSourceOffsets: stamped)
		#expect(initial.contains("https://one.example"))
		#expect(cached.contains("https://two.example"))
	}
	@Test(arguments: [false, true]) func continuationReferenceCache(stamped: Bool) {
		// A `]:` line that continues a paragraph is not a definition; the
		// preceding line must be part of the key so the two parses differ.
		let first = "[label][dest]\n\nintro\n[dest]: https://one.example\n"
		let second = "[label][dest]\n\nintro\n\n[dest]: https://one.example\n"
		let initial = MarkdownHTMLRenderer.renderBodyFragment(markdown: first, includeSourceOffsets: stamped)
		let cached = MarkdownHTMLRenderer.renderBodyFragment(markdown: second, includeSourceOffsets: stamped)
		#expect(!initial.contains(">label</a>"))
		#expect(cached.contains("<a href=\"https://one.example\">label</a>"))
	}
	@Test func definitionContextKeysOnlyDefinitionChunks() {
		let text = "para one\n\n> [a]:\n>   https://a.example\n\npara two\n\n[b]: https://b.example\n"
		let context = InlineParagraphMemo.definitionContext(in: text)
		#expect(context == "> [a]:\n>   https://a.example\n[b]: https://b.example\n")
		#expect(InlineParagraphMemo.definitionContext(in: "no definitions here") == "")
	}
	@Test func malformedCommentCannotExecuteScript() async throws {
		let source = "Before\n\n<div><!--x--!><script>window.__reviewExecuted='yes'</script></div>\n"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.waitQuiescent()
		let executed = try await harness.evaluate("typeof window.__reviewExecuted")
		#expect(executed == "undefined")
	}
	@Test func oversizedAuthoredStampDoesNotCrash() {
		let source = "Before\n\n<div data-s=\"9223372036854775807\">Authored HTML</div>\n"
		let old = MarkdownHTMLRenderer.renderBlockFragments(markdown: source, includeSourceOffsets: true)
		let cached = MarkdownHTMLRenderer.renderBlockFragments(markdown: "New prefix\n\n" + source, includeSourceOffsets: true, baseline: old)
		#expect(!cached.map(\.html).joined().contains("9223372036854775807"))
	}
	@Test func authoredStampAttributesAreNotRebased() {
		let source = "Before\n\n<div data-s=\"123\">Authored HTML</div>\n"
		let old = MarkdownHTMLRenderer.renderBlockFragments(markdown: source, includeSourceOffsets: true)
		let changed = "New prefix\n\n" + source
		let cached = MarkdownHTMLRenderer.renderBlockFragments(markdown: changed, includeSourceOffsets: true, baseline: old)
		let fresh = MarkdownHTMLRenderer.renderBlockFragments(markdown: changed, includeSourceOffsets: true)
		#expect(cached == fresh)
		#expect(!cached.map(\.html).joined().contains("data-s=\"123\""))
	}
	@Test func fenceCacheAfterRemovingPrecedingNewline() {
		let source = "prefix\n```\n# code\n```"
		let ranges = MarkdownSyntaxHighlighter.fenceRanges(in: source)
		let changed = "prefix```\n# code\n```"
		let cached = MarkdownFenceRangeTracker.updating(ranges, after: NSRange(location: 6, length: 0), delta: -1, in: changed as NSString)
		let fresh = MarkdownSyntaxHighlighter.fenceRanges(in: changed)
		#expect(cached == nil || cached == fresh)
	}
	@Test(arguments: [false, true]) func failedPDFCapturesMustFailExport(invalidData: Bool) async {
		let webView = FailedPDFWebView()
		webView.invalidData = invalidData
		let data = await MarkdownPDFRenderer.paginate(webView: webView, contentHeight: 2000,
			margin: 40, unbreakable: [], headings: [])
		#expect(data == nil)
		#expect(webView.captureCount == 1)
	}

}

@MainActor private final class FailedPDFWebView: WKWebView {
	var invalidData = false
	var captureCount = 0
	override func __createPDF(with configuration: WKPDFConfiguration?, completionHandler: @escaping @MainActor @Sendable (Data?, (any Error)?) -> Void) {
		captureCount += 1
		if invalidData { completionHandler(Data("not a PDF".utf8), nil) }
		else { completionHandler(nil, URLError(.cannotDecodeContentData)) }
	}
}

extension ReviewRegressionTests {
	@Test(arguments: ["<!--x--!>", "<!-->", "<!--->", "<!-- ordinary -->"])
	func commentEndingsDoNotHideExecutableTags(comment: String) {
		let html = HTMLPassthroughSanitizer.sanitize("<div>" + comment + "<script>bad()</script><span onclick='bad()'>safe</span></div>")
		#expect(!html.contains("<script"))
		#expect(!html.contains("onclick"))
		#expect(html.contains("safe"))
		let stamped = comment + "<span data-s=\"10\">text</span>"
		#expect(MarkdownBlockFragment.firstStamp(in: stamped) == 10)
		#expect(MarkdownBlockFragment.shiftingStamps(in: stamped, by: 1) == comment + "<span data-s=\"11\">text</span>")
	}

	@Test func onlyRealStampAttributesAreRebased() {
		let html = """
		<div title='data-s="9223372036854775807"'>data-s="123"<!-- data-s="456" --><span data-s="10">text</span></div>
		"""
		#expect(MarkdownBlockFragment.firstStamp(in: html) == 10)
		#expect(MarkdownBlockFragment.shiftingStamps(in: html, by: 5) == html.replacingOccurrences(of: "<span data-s=\"10\">", with: "<span data-s=\"15\">"))
		#expect(MarkdownBlockFragment.rewritingStamps(in: html, base: 10) == html.replacingOccurrences(of: "<span data-s=\"10\">", with: "<span data-s=\"0\">"))
	}

	@Test func overflowingStampsAreIgnored() {
		let tooLarge = "<span data-s=\"92233720368547758080\">x</span>"
		#expect(MarkdownBlockFragment.firstStamp(in: tooLarge) == nil)
		#expect(MarkdownBlockFragment.shiftingStamps(in: tooLarge, by: 1) == tooLarge)
		let maximum = "<span data-s=\"\(Int.max)\">x</span>"
		#expect(MarkdownBlockFragment.shiftingStamps(in: maximum, by: 1) == maximum)
	}

	@Test func reservedAttributesAreRemovedInAnyCasing() {
		#expect(HTMLPassthroughSanitizer.sanitize("<div DATA-S='10' data-md-escaped-pipe-s='20' data-label='ok'>text</div>") == "<div data-label=\"ok\">text</div>")
	}

	@Test func failedPageStopsCaptureImmediately() async {
		var captured: [CGFloat] = []
		let completed = await MarkdownPDFRenderer.forEachPageSlice(tops: [0, 720, 1440], contentHeight: 2000, printHeight: 720) { top, _ in
			captured.append(top)
			return top == 0
		}
		#expect(!completed)
		#expect(captured == [0, 720])
	}
}
