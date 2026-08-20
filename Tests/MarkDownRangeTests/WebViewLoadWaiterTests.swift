import Testing
import WebKit
@testable import MarkDownRange

@Suite(.serialized) @MainActor struct WebViewLoadWaiterTests {
	@Test func completionBeforeWaitIsRemembered() async throws {
		let waiter = WebViewLoadWaiter()
		let webView = WKWebView()
		waiter.webView(webView, didFinish: nil)
		try await waiter.wait(timeout: .milliseconds(50))
	}

	@Test func processTerminationFailsInsteadOfHanging() async {
		let waiter = WebViewLoadWaiter()
		let webView = WKWebView()
		waiter.webViewWebContentProcessDidTerminate(webView)
		do {
			try await waiter.wait(timeout: .seconds(1))
			Issue.record("Expected process termination to fail the load")
		} catch {
			#expect((error as? URLError)?.code == .networkConnectionLost)
		}
	}
}
