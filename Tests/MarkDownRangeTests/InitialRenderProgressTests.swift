#if os(macOS)
	import AppKit
#else
	import UIKit
#endif
import SwiftUI
import Testing
import WebKit
@testable import MarkDownRange

@Suite(.serialized)
@MainActor
struct InitialRenderProgressTests {
	@Test func reportsOnlyTheFirstStyledRenderLifecycle() async throws {
		var events: [Double?] = []
		let harness = try await CoordinatorBridgeHarness(
			source: "# First\n\nBody",
			onInitialRenderProgress: { progress in
				events.append(progress)
			})
		try await harness.waitUntil("initial render completion") {
			events.last.map { $0 == nil } == true
		}
		#expect(events == [0, 0.25, 0.75, nil])

		try await harness.replaceExternally("# First\n\nChanged body")
		try await harness.waitQuiescent()
		#expect(events == [0, 0.25, 0.75, nil])
	}

	@Test func consumesMatchingPreparedRenderAndKeepsEditingBaseline() async throws {
		let source = "# Prepared\n\nOriginal body"
		let prepared = MarkdownPreparedWebRender(
			markdown: source,
			theme: .default,
			fontSize: 14,
			includeSourceOffsets: true,
			interactiveCheckboxes: false,
			embedMermaidEngine: false,
			allowRemoteResources: false)
		let harness = try await CoordinatorBridgeHarness(
			source: source,
			preparedInitialRender: prepared)
		#expect(prepared.wasConsumed)
		#expect(try await harness.evaluate("document.body.textContent.includes('Original body') ? 'yes' : 'no'") == "yes")

		try await harness.replaceExternally("# Prepared\n\nChanged body")
		try await harness.waitQuiescent()
		#expect(try await harness.evaluate("document.body.textContent.includes('Changed body') ? 'yes' : 'no'") == "yes")
		#expect(try await harness.stampMismatches().isEmpty)
	}

	@Test func ignoresPreparedRenderWhenConfigurationChanged() async throws {
		let prepared = MarkdownPreparedWebRender(
			markdown: "# Stale",
			theme: .default,
			fontSize: 14,
			includeSourceOffsets: true,
			interactiveCheckboxes: false,
			embedMermaidEngine: false,
			allowRemoteResources: false)
		let harness = try await CoordinatorBridgeHarness(
			source: "# Current",
			preparedInitialRender: prepared)
		#expect(!prepared.wasConsumed)
		#expect(try await harness.evaluate("document.body.textContent.includes('Current') ? 'yes' : 'no'") == "yes")
	}

	@Test func productionDocumentEndScriptsAreInteractiveAtReady() async throws {
		var events: [Double?] = []
		var readyCount = 0
		let root = MarkdownWebView(
			text: "# Live\n\nEditable body", theme: .default, fontSize: 14)
			.editable(true)
			.onInitialRenderProgress { events.append($0) }
			.onInitialRenderReady { readyCount += 1 }
		let host = TestWindowHost(root)

		var webView: WKWebView?
		// Parallel WebKit-heavy suites can delay SwiftUI hierarchy installation
		// well beyond the usual subsecond path on loaded CI/developer hosts.
		for _ in 0..<400 {
			webView = findWebView(in: host.view)
			if events.last.map({ $0 == nil }) == true, webView != nil { break }
			try await Task.sleep(for: .milliseconds(25))
		}
		let loadedWebView = try #require(webView)
		#expect(events == [0, 0.25, 0.75, nil])
		#expect(readyCount == 1)
		#expect(try await evaluate(
			"document.body.contentEditable + '|' + typeof window.__mdSetRev",
			in: loadedWebView) == "true|function")
	}

	private func findWebView(in view: TestPlatformView) -> WKWebView? {
		if let webView = view as? WKWebView { return webView }
		for child in view.subviews {
			if let found = findWebView(in: child) { return found }
		}
		return nil
	}

	private func evaluate(_ script: String, in webView: WKWebView) async throws -> String? {
		try await withCheckedThrowingContinuation { continuation in
			webView.evaluateJavaScript(script) { result, error in
				if let error { continuation.resume(throwing: error) }
				else { continuation.resume(returning: result as? String) }
			}
		}
	}
}
