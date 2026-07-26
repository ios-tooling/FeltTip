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
	/// The post-edit caret hint delivered with the most recent onSourceEdit.
	private(set) var lastCaretHint: Int?
	/// Most recent selection report from the page, plus a count tests can wait
	/// on across the selectionchange debounce.
	private(set) var lastReportedSelection: NSRange?
	private(set) var selectionReportCount = 0
	let coordinator: MarkdownWebView.Coordinator
	let webView: WKWebView
	private let window: NSWindow
	private let checkboxToggle: ((Int, Bool) -> Void)?
	/// When true, the emulated SwiftUI round-trip is suppressed — the page
	/// never gets the re-render a structural edit expects, which is exactly
	/// the stuck-freeze condition the frozenTimeout safety net exists for.
	var suppressRoundTrip = false

	init(source: String, onCheckboxToggle: ((Int, Bool) -> Void)? = nil) async throws {
		self.source = source
		self.checkboxToggle = onCheckboxToggle
		var view = MarkdownWebView(text: source, theme: .default, fontSize: 14).editable(true)
		if let onCheckboxToggle { view = view.onCheckboxToggle(onCheckboxToggle) }
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
		var view = MarkdownWebView(text: text, theme: .default, fontSize: 14)
			.editable(true)
			.onSourceEdit { [weak self] newText, caretHint in
				guard let self else { return }
				self.source = newText
				self.sourceEditCount += 1
				self.lastCaretHint = caretHint
				guard !self.suppressRoundTrip else { return }
				// SwiftUI delivers the state change on a later main-actor turn.
				Task { @MainActor in
					self.wireRoundTrip(text: newText)
					self.coordinator.load(into: self.webView)
				}
			}
			.onSelectionChanged { [weak self] range in
				self?.lastReportedSelection = range
				self?.selectionReportCount += 1
			}
		if let checkboxToggle { view = view.onCheckboxToggle(checkboxToggle) }
		coordinator.parent = view
	}

	/// Push new text in from outside the page — the split-pane case, where the
	/// other editor is typing — which re-renders through the body-swap path.
	func replaceExternally(_ text: String) async throws {
		source = text
		wireRoundTrip(text: text)
		coordinator.load(into: webView)
	}

	/// Adopt text the host set directly (an undo/redo restore), keeping the
	/// harness's mirror of the source in step without counting an edit.
	func adoptHostText(_ text: String) {
		source = text
	}

	/// Record an edit that arrived while a test had swapped the parent view, so
	/// the standard round-trip wiring wasn't in place.
	func recordExternalEdit(_ text: String) {
		source = text
		sourceEditCount += 1
	}

	/// Put the standard round-trip wiring back after a test swapped the parent.
	func rewireRoundTrip() {
		wireRoundTrip(text: source)
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

	/// Every stamped run's text must equal the source at its own stamp — the
	/// invariant the whole offset-mapping scheme rests on. Returns a
	/// description of each violation (empty when the page and source agree),
	/// so a test can assert it after any edit sequence, however exotic.
	func stampMismatches() async throws -> [String] {
		let dump = try await evaluate("""
			Array.from(document.querySelectorAll('[data-s]'))
			  .map(e => e.getAttribute('data-s') + '\\u0001' + e.textContent)
			  .join('\\u0002')
			""") ?? ""
		let ns = source as NSString
		var problems: [String] = []
		for entry in dump.components(separatedBy: "\u{2}") where !entry.isEmpty {
			let parts = entry.components(separatedBy: "\u{1}")
			guard parts.count == 2, let stamp = Int(parts[0]) else { continue }
			let shown = normalized(parts[1])
			guard !shown.isEmpty else { continue }   // caret-holder span
			let length = (shown as NSString).length
			guard stamp >= 0, stamp + length <= ns.length else {
				problems.append("run at \(stamp) (\(quoted(shown))) runs past the \(ns.length)-char source")
				continue
			}
			let inSource = normalized(ns.substring(with: NSRange(location: stamp, length: length)))
			if inSource != shown {
				problems.append("run at \(stamp) shows \(quoted(shown)) but source has \(quoted(inSource))")
			}
		}
		return problems
	}

	private func normalized(_ s: String) -> String {
		s.replacingOccurrences(of: "\u{00A0}", with: " ")
	}

	private func quoted(_ s: String) -> String {
		"\"\(s.replacingOccurrences(of: "\n", with: "\\n"))\""
	}

	func stamps() async throws -> String {
		try await evaluate("Array.from(document.querySelectorAll('[data-s]')).map(e => e.getAttribute('data-s')).join(',')") ?? ""
	}

	func waitForSourceEdits(_ count: Int) async throws {
		try await waitUntil("source edit \(count)") { self.sourceEditCount >= count }
	}

	/// Wait until the emulated round-trip settles: renders happen off the main
	/// actor now, so "settled" means the page ADDRESSES the coordinator's
	/// current revision (a stale page's stamped content must not count) and
	/// has stamped content again.
	func waitQuiescent() async throws {
		try await Task.sleep(for: .milliseconds(80))
		try await waitUntil("page at current revision with stamped content") {
			let pageRev = try await self.evaluate("window.__mdGetRev ? String(window.__mdGetRev()) : 'none'")
			guard pageRev == String(self.coordinator.currentRev) else { return false }
			return try await self.evaluate("document.querySelector('[data-s]') ? 'yes' : 'no'") == "yes"
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
