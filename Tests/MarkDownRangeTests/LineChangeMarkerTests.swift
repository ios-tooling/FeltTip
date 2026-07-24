#if os(macOS)
	import AppKit
	import Testing
	import WebKit
	@testable import MarkDownRange

/// Drives the change-marker script in a live WKWebView: the host sends git
/// diff ranges keyed to `data-s` source offsets and the page must grow (and
/// clear) `.mdr-change-marker` edge bars.
@Suite(.serialized) @MainActor struct LineChangeMarkerTests {
	@Test func markersAppearClearAndSurviveBodySwaps() async throws {
		let source = "Alpha\n\nBeta\n\nGamma"
		let webView = try await makeWebView(source: source)

		// "Beta" occupies offsets 7..<11: one added range plus one deletion tick.
		let changes = MarkdownLineChanges(
			changedLines: [2: .added],
			deletionsAfter: [3],
			changedRanges: [.init(range: 7..<11, kind: .added)],
			deletionOffsets: [12]
		)
		let json = MarkdownWebView.Coordinator.lineChangesJSON(changes)
		// Redraws are coalesced onto a short timer now, so poll rather than
		// asserting synchronously.
		try await run(webView, "window.__mdSetLineChanges(\(json))")
		try await waitUntil("a bar and a tick") {
			try await self.markerCount(webView) == "2"
		}

		// A body swap rebuilds the DOM; the markers must be redrawn from state.
		try await run(webView, "window.__mdSwapContent(document.body.innerHTML)")
		try await waitUntil("markers redrawn after swap") {
			try await self.markerCount(webView) == "2"
		}

		// nil state clears everything.
		try await run(webView, "window.__mdSetLineChanges(null)")
		try await waitUntil("markers cleared") {
			try await self.markerCount(webView) == "0"
		}
	}

	@Test func jsonEncodesRangesKindsAndDeletions() {
		let changes = MarkdownLineChanges(
			changedLines: [0: .modified],
			deletionsAfter: [-1],
			changedRanges: [.init(range: 0..<5, kind: .modified), .init(range: 9..<12, kind: .added)],
			deletionOffsets: [0]
		)
		let json = MarkdownWebView.Coordinator.lineChangesJSON(changes)
		#expect(json == #"{"ranges":[{"s":0,"e":5,"k":"m"},{"s":9,"e":12,"k":"a"}],"deletions":[0]}"#)
		#expect(MarkdownWebView.Coordinator.lineChangesJSON(nil) == "null")
	}

	// MARK: Plumbing

	private func makeWebView(source: String) async throws -> WKWebView {
		let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
		let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
		window.contentView = webView
		window.orderFront(nil)
		let html = MarkdownHTMLRenderer.renderDocument(markdown: source, includeSourceOffsets: true)
		webView.loadHTMLString(html, baseURL: nil)
		try await waitUntil("stamped content") {
			try await self.evaluate(webView, "document.querySelector('[data-s]') ? 'yes' : 'no'") == "yes"
		}
		try await run(webView, MarkdownWebView.Coordinator.scrollSyncScript)
		return webView
	}

	private func markerCount(_ webView: WKWebView) async throws -> String? {
		try await evaluate(webView, "String(document.querySelectorAll('.mdr-change-marker').length)")
	}

	private func evaluate(_ webView: WKWebView, _ script: String) async throws -> String? {
		try await withCheckedThrowingContinuation { continuation in
			webView.evaluateJavaScript(script) { result, error in
				if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: result as? String) }
			}
		}
	}

	private func run(_ webView: WKWebView, _ script: String) async throws {
		_ = try await evaluate(webView, "(function () { \(script); return 'ok'; })()")
	}

	private func waitUntil(_ label: String, _ condition: () async throws -> Bool) async throws {
		for _ in 0..<100 {
			if try await condition() { return }
			try await Task.sleep(for: .milliseconds(20))
		}
		Issue.record("timed out waiting for \(label)")
	}
}
#endif
