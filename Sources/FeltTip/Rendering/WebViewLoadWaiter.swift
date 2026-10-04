import Foundation
import WebKit

/// One-shot navigation waiter that is safe when completion races registration,
/// and that cannot suspend an export forever after a WebContent crash.
@MainActor
final class WebViewLoadWaiter: NSObject, WKNavigationDelegate {
	private var result: Result<Void, Error>?
	private var continuations: [CheckedContinuation<Void, Error>] = []
	private var timeoutTasks: [Task<Void, Never>] = []

	func wait(timeout: Duration = .seconds(15)) async throws {
		if let result { return try result.get() }
		try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				if let result {
					continuation.resume(with: result)
					return
				}
				continuations.append(continuation)
				timeoutTasks.append(Task { @MainActor [weak self] in
					try? await Task.sleep(for: timeout)
					guard !Task.isCancelled else { return }
					self?.finish(.failure(URLError(.timedOut)))
				})
			}
		} onCancel: {
			Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
		}
	}

	private func finish(_ result: Result<Void, Error>) {
		guard self.result == nil else { return }
		self.result = result
		timeoutTasks.forEach { $0.cancel() }
		timeoutTasks.removeAll()
		let continuations = continuations
		self.continuations.removeAll()
		continuations.forEach { $0.resume(with: result) }
	}

	func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
	func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
		finish(.failure(error))
	}
	func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
		finish(.failure(error))
	}
	func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
		finish(.failure(URLError(.networkConnectionLost)))
	}
}
