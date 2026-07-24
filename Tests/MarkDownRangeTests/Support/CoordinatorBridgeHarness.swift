//
//  CoordinatorBridgeHarness.swift
//  MarkDownRangeTests
//
//  Drives the REAL MarkdownWebView.Coordinator against a live WKWebView: the
//  same message handler, revision gate, selfEdit skip, freeze lifecycle, and
//  resync paths the app runs — only the SwiftUI round-trip is emulated (an
//  onSourceEdit callback that updates the parent and calls load(into:) on the
//  next main-actor turn, like updateNSView would). This is the deterministic
//  seam between the pure splicer tests and the full-app UI tests.
//

#if os(macOS)
import AppKit
import Testing
import WebKit
@testable import MarkDownRange

@MainActor
final class CoordinatorBridgeHarness {
	private(set) var source: String
	private(set) var sourceEditCount = 0
	let coordinator: MarkdownWebView.Coordinator
	let webView: WKWebView
	private let window: NSWindow
	/// When true, the emulated SwiftUI round-trip is suppressed — the page
	/// never gets the re-render a structural edit expects, which is exactly
	/// the stuck-freeze condition the frozenTimeout safety net exists for.
	var suppressRoundTrip = false

	init(source: String) async throws {
		self.source = source
		let view = MarkdownWebView(text: source, theme: .default, fontSize: 14).editable(true)
		coordinator = MarkdownWebView.Coordinator(parent: view)
		let config = WKWebViewConfiguration()
		config.userContentController.add(WeakScriptMessageHandler(coordinator), name: "mdedit")
		webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: config)
		webView.navigationDelegate = coordinator
		coordinator.webView = webView
		window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
		window.contentView = webView
		window.orderFront(nil)
		wireRoundTrip(text: source)
		coordinator.load(into: webView)
		try await waitUntil("initial stamped content") {
			try await self.evaluate("document.querySelector('[data-s]') && window.__mdSetRev ? 'yes' : 'no'") == "yes"
		}
	}

	/// Rebuild the parent view the way updateNSView sees a fresh one after a
	/// state change, keeping the onSourceEdit wiring alive.
	private func wireRoundTrip(text: String) {
		coordinator.parent = MarkdownWebView(text: text, theme: .default, fontSize: 14)
			.editable(true)
			.onSourceEdit { [weak self] newText in
				guard let self else { return }
				self.source = newText
				self.sourceEditCount += 1
				guard !self.suppressRoundTrip else { return }
				// SwiftUI delivers the state change on a later main-actor turn.
				Task { @MainActor in
					self.wireRoundTrip(text: newText)
					self.coordinator.load(into: self.webView)
				}
			}
	}

	/// Run several editing commands in ONE JavaScript turn — the same shape as
	/// a batched WebKit editing turn (quote + retrocurl, autocorrect + insert).
	func batch(_ commands: [String]) async throws {
		try await run(commands.joined(separator: ";\n"))
	}

	func placeCaret(_ offset: Int) async throws {
		try await run("window.__mdPlaceCaret(\(offset))")
	}

	func type(_ text: String, at offset: Int? = nil) async throws {
		let place = offset.map { "window.__mdPlaceCaret(\($0));" } ?? ""
		try await run("\(place) document.execCommand('insertText', false, \(json(text)))")
	}

	/// The text of every stamped run in document order — the DOM's projection
	/// of the source. Convergence oracle for the fuzz suite.
	func domProjectedText() async throws -> String {
		// Empty runs are caret artifacts (__mdPlaceCaret's synthesized holder
		// spans), not content — exclude them from the projection.
		try await evaluate("Array.from(document.querySelectorAll('[data-s]')).map(e => e.textContent).filter(t => t.length).join('|')") ?? ""
	}

	func stamps() async throws -> String {
		try await evaluate("Array.from(document.querySelectorAll('[data-s]')).map(e => e.getAttribute('data-s')).join(',')") ?? ""
	}

	func waitForSourceEdits(_ count: Int) async throws {
		try await waitUntil("source edit \(count)") { self.sourceEditCount >= count }
	}

	/// Wait until the emulated round-trip settles: no reload pending and the
	/// page has (re)gained stamped content.
	func waitQuiescent() async throws {
		try await Task.sleep(for: .milliseconds(80))
		try await waitUntil("quiescent stamped content") {
			try await self.evaluate("document.querySelector('[data-s]') ? 'yes' : 'no'") == "yes"
		}
	}

	func evaluate(_ script: String) async throws -> String? {
		try await withCheckedThrowingContinuation { continuation in
			webView.evaluateJavaScript(script) { result, error in
				if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: result as? String) }
			}
		}
	}

	func run(_ script: String) async throws {
		_ = try await evaluate("(function () { \(script); return 'ok'; })()")
	}

	private func json(_ s: String) -> String {
		String(data: try! JSONEncoder().encode(s), encoding: .utf8)!
	}

	func waitUntil(_ label: String, _ condition: () async throws -> Bool) async throws {
		for _ in 0..<100 {
			if try await condition() { return }
			try await Task.sleep(for: .milliseconds(50))
		}
		Issue.record("timed out waiting for \(label)")
	}
}
#endif
