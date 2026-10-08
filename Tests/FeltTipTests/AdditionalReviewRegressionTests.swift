import Foundation
import Testing
import WebKit
@testable import FeltTip

@Suite(.serialized) @MainActor struct AdditionalReviewRegressionTests {
	@Test(arguments: ["noscript", "xmp", "title"])
	func rawTextCannotExecute(tag: String) async throws {
		let source = "Before\n\n<div><\(tag)><span title=\"</\(tag)><script>window.__secondReview='yes'</script>\">tail</span></div>\n"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.waitQuiescent()
		let result = try await harness.evaluate("typeof window.__secondReview")
		#expect(result == "undefined")
	}
	@Test func checkboxEnumerationIgnoresFences() {
		let source = "```\n- [x] example\n```\n\n- [ ] real\n"
		#expect(MarkdownWebView.Coordinator.checkboxState(at: 0, in: source) == false)
	}
	@Test func creatingFenceWithNewlineInvalidates() {
		let before = "prefix```\ncode"
		let after = "prefix\n```\ncode"
		let old = MarkdownSyntaxHighlighter.fenceRanges(in: before)
		let cached = MarkdownFenceRangeTracker.updating(old, after: NSRange(location: 6, length: 1), delta: 1, in: after as NSString)
		let fresh = MarkdownSyntaxHighlighter.fenceRanges(in: after)
		#expect(cached == nil || cached == fresh)
	}
}

extension AdditionalReviewRegressionTests {
	@Test(arguments: ["```\n- [x] example\n```\n\n- [ ] real\n"])
	func realCheckboxReachesHost(source: String) async throws {
		var toggles = 0
		let harness = try await CoordinatorBridgeHarness(source: source, onCheckboxToggle: { _, _ in toggles += 1 })
		try await harness.run("var box = document.querySelector('input[data-cb]'); box.checked = true; box.dispatchEvent(new Event('change', {bubbles:true}));")
		try await harness.waitUntil("checkbox callback") { toggles == 1 }
		#expect(toggles == 1)
	}
	@Test func rewritingLinkDoesNotModifyExample() {
		let source = "`[example](https://old.com)`\n\n[real](https://old.com)"
		let result = MarkdownLinkRewriter.replacingDestination(in: source, currentURL: "https://old.com", occurrence: 0, with: "https://new.com")
		#expect(result == "`[example](https://old.com)`\n\n[real](https://new.com)")
	}
	@Test func rewritingLinkRequiresWholeDestination() {
		let source = "[other](https://old.com/path) [target](https://old.com)"
		let result = MarkdownLinkRewriter.replacingDestination(in: source, currentURL: "https://old.com", occurrence: 0, with: "https://new.com")
		#expect(result == "[other](https://old.com/path) [target](https://new.com)")
	}
}

extension AdditionalReviewRegressionTests {
	@Test(arguments: ["noscript", "xmp", "title", "textarea", "plaintext"])
	func selfClosingRawTextElementsAreNotPreserved(tag: String) {
		let source = "<div><\(tag)/><span title=\"</\(tag)><script>bad()</script>\">tail</span></div>"
		let clean = HTMLPassthroughSanitizer.sanitize(source)
		#expect(!clean.contains("<script"))
		#expect(!clean.contains("<\(tag)"))
	}

	@Test func checkboxEnumerationIgnoresFrontmatterAndNestedCode() {
		let source = "---\nexample: |\n  - [x] example\n---\n\n- [ ] parent\n  - [x] child\n\n    ```\n    - [ ] example\n    ```\n\n- [x] final\n"
		#expect(MarkdownWebView.Coordinator.checkboxState(at: 0, in: source) == false)
		#expect(MarkdownWebView.Coordinator.checkboxState(at: 1, in: source) == true)
		#expect(MarkdownWebView.Coordinator.checkboxState(at: 2, in: source) == true)
		#expect(MarkdownWebView.Coordinator.checkboxState(at: 3, in: source) == nil)
	}

	@Test func deletingPrefixCanCreateFence() {
		let before = "x```\ncode"
		let after = "```\ncode"
		let cached = MarkdownFenceRangeTracker.updating(MarkdownSyntaxHighlighter.fenceRanges(in: before), after: NSRange(location: 0, length: 0), delta: -1, in: after as NSString)
		#expect(cached == nil || cached == MarkdownSyntaxHighlighter.fenceRanges(in: after))
	}

	@Test func referenceEditIgnoresFencedDefinitions() {
		let source = "```\n[id]: https://old.com\n```\n\n[a][id] [b][id]\n\n[id]:\n  https://old.com\n"
		let result = MarkdownLinkRewriter.replacingDestination(in: source, currentURL: "https://old.com", occurrence: 1, with: "https://new.com")
		#expect(result == "```\n[id]: https://old.com\n```\n\n[a][id] [b][id]\n\n[id]:\n  https://new.com\n")
	}

	@Test func encodedSeparatorsDoNotMatchDifferentURLs() {
		let source = "[other](https://site.test/a/b) [target](https://site.test/a%2Fb)"
		let result = MarkdownLinkRewriter.replacingDestination(in: source, currentURL: "https://site.test/a%2Fb", occurrence: 0, with: "https://new.com")
		#expect(result == "[other](https://site.test/a/b) [target](https://new.com)")
	}

	@Test func linkRangesPreserveUnicodeLabelsAndTitles() {
		let source = "😀 [café](https://old.com \"title\") and <https://old.com>"
		#expect(MarkdownLinkRewriter.replacingDestination(in: source, currentURL: "https://old.com", occurrence: 0, with: "https://new.com") == "😀 [café](https://new.com \"title\") and <https://old.com>")
		#expect(MarkdownLinkRewriter.replacingDestination(in: source, currentURL: "https://old.com", occurrence: 1, with: "https://new.com") == "😀 [café](https://old.com \"title\") and <https://new.com>")
	}
}

extension AdditionalReviewRegressionTests {
	@Test(arguments: ["\n", "\r\n"])
	func newlineCanCreateEarlierClosingFence(newline: String) {
		let before = "```" + newline + "prefix```" + newline + "code"
		let location = ("```" + newline + "prefix" as NSString).length
		let after = (before as NSString).replacingCharacters(in: NSRange(location: location, length: 0), with: newline)
		let cached = MarkdownFenceRangeTracker.updating(
			MarkdownSyntaxHighlighter.fenceRanges(in: before),
			after: NSRange(location: location, length: (newline as NSString).length),
			delta: (newline as NSString).length, in: after as NSString)
		#expect(cached == nil || cached == MarkdownSyntaxHighlighter.fenceRanges(in: after))
	}
}
