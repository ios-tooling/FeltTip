import Testing
import WebKit
@testable import FeltTip

@Suite(.serialized) @MainActor struct WebViewLoadWaiterTests {
	@Test func completionBeforeWaitIsRemembered() async throws {
		let waiter = WebViewLoadWaiter()
		let webView = makeIsolatedWebView()
		waiter.webView(webView, didFinish: nil)
		try await waiter.wait(timeout: .milliseconds(50))
	}

	@Test func processTerminationFailsInsteadOfHanging() async {
		let waiter = WebViewLoadWaiter()
		let webView = makeIsolatedWebView()
		waiter.webViewWebContentProcessDidTerminate(webView)
		do {
			try await waiter.wait(timeout: .seconds(1))
			Issue.record("Expected process termination to fail the load")
		} catch {
			#expect((error as? URLError)?.code == .networkConnectionLost)
		}
	}

	@Test func concurrentWaitersBothResumeWhenNavigationFinishes() async {
		let waiter = WebViewLoadWaiter()
		let webView = makeIsolatedWebView()
		let first = Task { try await waiter.wait(timeout: .seconds(1)) }
		await Task.yield()
		let second = Task { try await waiter.wait(timeout: .seconds(1)) }
		await Task.yield()
		waiter.webView(webView, didFinish: nil)

		do {
			let _: Void = try await BoundedTestCallbackWaiter.wait(timeout: .seconds(1)) { completion in
				Task { @MainActor in
					do {
						try await first.value
						try await second.value
						completion(.success(()))
					} catch {
						completion(.failure(error))
					}
				}
			}
		} catch {
			Issue.record("Concurrent waiters did not both resume: \(error)")
		}
	}
}
