#if os(macOS)
import AppKit
import Testing
import WebKit
@testable import FeltTip

@Suite @MainActor struct FindCountOrderingTests {
	private final class DelayedWebView: WKWebView {
		var completions: [@MainActor @Sendable (Any?, (any Error)?) -> Void] = []
		override func evaluateJavaScript(_ script: String, completionHandler: (@MainActor @Sendable (Any?, (any Error)?) -> Void)? = nil) {
			if let completionHandler { completions.append(completionHandler) }
		}
	}
	@Test func clearingSearchDiscardsPendingCount() {
		let web = DelayedWebView()
		let host = MarkdownWebViewFindHost(webView: web)
		host.updateMatchCount(for: "old")
		host.updateMatchCount(for: "")
		web.completions[0](7, nil)
		#expect(host.matchCountLabel.stringValue.isEmpty)
	}
	@Test func newerCountWinsOutOfOrderCallbacks() {
		let web = DelayedWebView()
		let host = MarkdownWebViewFindHost(webView: web)
		host.updateMatchCount(for: "old")
		host.updateMatchCount(for: "new")
		web.completions[1](2, nil)
		web.completions[0](7, nil)
		#expect(host.matchCountLabel.stringValue == "2 results")
	}
}
#endif
