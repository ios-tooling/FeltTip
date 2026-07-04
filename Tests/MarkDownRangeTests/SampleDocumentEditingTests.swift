#if os(macOS)
	import AppKit
	import Testing
	import WebKit
	@testable import MarkDownRange

/// Full-pipeline editing tests over a real release-notes document
/// (curly quotes, em dashes, bold runs, an emoji): a live WKWebView runs the
/// production editor script, the production `Coordinator` applies the
/// splices, and `EditorHost` mirrors the SwiftUI round-trip `updateNSView`
/// performs in the app. Each test moves the caret the way a user would —
/// beginning, end, back toward the start — and requires every keystroke to
/// land in the source exactly where the caret sat.
@MainActor
private final class EditorHost: NSObject, WKScriptMessageHandler {
	private(set) var text: String
	let webView: WKWebView
	let coordinator: MarkdownWebView.Coordinator
	private let window: NSWindow

	init(text: String) {
		self.text = text
		let config = WKWebViewConfiguration()
		webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 900), configuration: config)
		coordinator = MarkdownWebView.Coordinator(parent: MarkdownWebView(text: text, theme: .default, fontSize: 16).editable(true))
		window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
		super.init()
		config.userContentController.add(self, name: "mdedit")
		webView.navigationDelegate = coordinator
		coordinator.webView = webView
		window.contentView = webView
		window.orderFront(nil)
		updateParent()
		coordinator.load(into: webView)
	}

	/// Mirrors `updateNSView`: a source edit updates the host's text, which
	/// hands the coordinator a fresh parent value and re-runs `load`.
	private func updateParent() {
		coordinator.parent = MarkdownWebView(text: text, theme: .default, fontSize: 16)
			.editable(true)
			.onSourceEdit { [weak self] new in
				guard let self else { return }
				self.text = new
				self.updateParent()
				self.coordinator.load(into: self.webView)
			}
	}

	func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
		coordinator.userContentController(controller, didReceive: message)
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

	/// Waits for an editable page. After a structural edit's re-render, pass a
	/// substring of the new DOM text — the old page also has `__mdPlaceCaret`,
	/// so readiness alone can't tell the two apart.
	func waitUntilReady(domContains probe: String? = nil) async throws {
		let content = probe.map { "document.body.textContent.indexOf('\($0)') >= 0" } ?? "!!document.querySelector('[data-s]')"
		for _ in 0..<100 {
			if try await evaluate("typeof window.__mdPlaceCaret === 'function' && \(content) ? 'yes' : 'no'") == "yes" { return }
			try await Task.sleep(for: .milliseconds(50))
		}
		Issue.record("editor page never became ready (probe: \(probe ?? "-"))")
	}

	/// Waits until a `window.__testNonce = 1` stamped before a structural edit
	/// has been wiped by the resulting reload — proof the fresh page is up.
	func waitForFreshPage() async throws {
		for _ in 0..<100 {
			if try await evaluate("typeof window.__testNonce === 'undefined' ? 'yes' : 'no'") == "yes" { return }
			try await Task.sleep(for: .milliseconds(50))
		}
		Issue.record("page never reloaded after structural edit")
	}
}

@Suite(.serialized) @MainActor struct SampleDocumentEditingTests {
	private static let fixtureURL = URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent()
		.appendingPathComponent("Fixtures/SuperDuper-0.6.0.md")

	private func makeHost() async throws -> EditorHost {
		let source = try String(contentsOf: Self.fixtureURL, encoding: .utf8)
		let host = EditorHost(text: source)
		try await host.waitUntilReady()
		return host
	}

	// MARK: Scenarios

	@Test func typingAtBeginningThenEnd() async throws {
		let host = try await makeHost()
		try await type("QA", before: "Welcome to SuperDuper!", in: host)
		try await type("QB", after: "Shirt 👕 Pocket", in: host)
	}

	@Test func editsMarchingBackwardThroughTheDocument() async throws {
		let host = try await makeHost()
		try await type("M1", after: "Thanks, as always, for your help!", in: host)
		try await type("M2", after: "say something", in: host)
		// Mid-run inside the bold text: a caret at the exact start of a bold
		// run is normalized by WebKit to the equivalent position in the
		// preceding run, so anchoring there would be ambiguous.
		try await type("M3", before: "Report", in: host)
		try await type("M4", after: "Here’s the next update", in: host)
		try await type("M5", before: "Welcome", in: host)
	}

	@Test func repeatedEditsAtTheSameSpot() async throws {
		let host = try await makeHost()
		// Each pass recomputes the offset from the current text, so any stamp
		// drift from the previous insertion shows up as a misplaced splice.
		for n in 1...5 {
			try await type("R\(n)x", after: "polish, resilience", in: host)
		}
	}

	@Test func editingHeadingsAndListItems() async throws {
		let host = try await makeHost()
		try await type("H1", after: "What’s new", in: host)
		try await type("H2", after: "A little more polish", in: host)
		try await type("L1", after: "you don’t have to aim", in: host)
		try await type("L2", after: "no longer have to press Return", in: host)
		try await type("H3", after: "Loose lips", in: host)
	}

	@Test func typingAroundTheEmoji() async throws {
		let host = try await makeHost()
		// Right after the surrogate pair, then between it and the next word,
		// then earlier in the same run — within-run offsets past an emoji.
		try await type("P1", after: "Shirt 👕", in: host)
		try await type("P2", before: "Pocket", in: host)
		try await type("P3", after: "—Dave Nanian", in: host)
	}

	@Test func editsInterleavedForwardAndBackward() async throws {
		let host = try await makeHost()
		try await type("F1", after: "mostly about polish", in: host)
		try await type("F2", after: "stay a surprise", in: host)
		try await type("F3", after: "genuinely pauses", in: host)
		try await type("F4", after: "your shared note", in: host)
		try await type("F5", after: "mostly about polish", in: host)
	}

	@Test func typingInsideStyledAndPunctuatedRuns() async throws {
		let host = try await makeHost()
		// Inside a bold run.
		try await type("S1", after: "correct, current", in: host)
		// Right after an em dash inside a long paragraph.
		try await type("S2", after: "do anything—", in: host)
		// Between curly quotes.
		try await type("S3", after: "briefly see “Pausing…", in: host)
		// After the ASCII straight quotes further down.
		try await type("S4", after: "\"no jobs yet\"", in: host)
	}

	@Test func burstTypingThenEditElsewhere() async throws {
		let host = try await makeHost()
		// Three separate keystrokes in one script — each is its own
		// beforeinput/input cycle chained off the previous edit's offsets.
		let ns = host.text as NSString
		let anchor = ns.range(of: "resumes cleanly")
		#expect(anchor.location != NSNotFound)
		let offset = anchor.location + anchor.length
		let expected = ns.replacingCharacters(in: NSRange(location: offset, length: 0), with: "ABC")
		try await host.run("window.__mdPlaceCaret(\(offset)); document.execCommand('insertText', false, 'A'); document.execCommand('insertText', false, 'B'); document.execCommand('insertText', false, 'C');")
		try await waitForText(expected, in: host, context: "burst typing ABC")
		try await type("D1", before: "Bootable copies", in: host)
		try await type("D2", after: "Erase-then-copy", in: host)
	}

	@Test func deletingThenTypingEarlier() async throws {
		let host = try await makeHost()
		try await deleteBackward(3, endingAt: "to be clearer", in: host)
		try await type("E1", after: "didn’t behave", in: host)
		try await deleteBackward(5, endingAt: "overall well intentioned", in: host)
		try await type("E2", before: "Fixes", in: host)
	}

	@Test func typingOverASelectionWithinOneRun() async throws {
		let host = try await makeHost()
		// Select "whining" backward from the caret and type over it — a
		// non-collapsed insertText whose replaced text is verified exactly.
		let ns = host.text as NSString
		let word = ns.range(of: "whining")
		#expect(word.location != NSNotFound)
		let expected = ns.replacingCharacters(in: word, with: "grumbling")
		try await host.run("""
			window.__mdPlaceCaret(\(word.location + word.length));
			var sel = window.getSelection();
			for (var i = 0; i < \(word.length); i++) sel.modify('extend', 'backward', 'character');
			document.execCommand('insertText', false, 'grumbling');
			""")
		try await waitForText(expected, in: host, context: "typing over selected word")
		try await type("W1", after: "Here’s the next update", in: host)
	}

	@Test func typingOverASelectionAcrossABoldBoundary() async throws {
		let host = try await makeHost()
		// The DOM selection "ise—please" spans a plain run and a bold run; the
		// source range between the two caret positions includes the `**`, so
		// the splice replaces "ise—**please" and triggers a re-render.
		let ns = host.text as NSString
		let sourceSpan = ns.range(of: "ise—**please")
		#expect(sourceSpan.location != NSNotFound)
		let expected = ns.replacingCharacters(in: sourceSpan, with: "X")
		let caret = ns.range(of: "please keep it").location + "please".utf16.count
		try await host.run("""
			window.__mdPlaceCaret(\(caret));
			var sel = window.getSelection();
			for (var i = 0; i < 10; i++) sel.modify('extend', 'backward', 'character');
			document.execCommand('insertText', false, 'X');
			""")
		try await waitForText(expected, in: host, context: "typing over cross-run selection")
		// The structural path re-renders; wait for the new page (the old one
		// stays frozen) before editing again.
		try await host.waitUntilReady(domContains: "surprX keep")
		try await type("X2", after: "Loose lips", in: host)
	}

	@Test func backspaceAtParagraphStartMergesParagraphs() async throws {
		let host = try await makeHost()
		// Backspace at the start of a paragraph following a *plain* one: the
		// splice removes the "\n\n" separator and re-renders the merged block.
		let ns = host.text as NSString
		let separator = ns.range(of: "send email.\n\nThanks")
		#expect(separator.location != NSNotFound)
		let expected = ns.replacingCharacters(in: NSRange(location: separator.location + "send email.".utf16.count, length: 2), with: "")
		let caret = ns.range(of: "Thanks, as always").location
		// The old page's textContent already reads "email.Thanks" (adjacent
		// blocks join bare), so page freshness is detected via a nonce the
		// re-render drops rather than a content probe.
		try await host.run("window.__testNonce = 1; window.__mdPlaceCaret(\(caret)); document.execCommand('delete');")
		try await waitForText(expected, in: host, context: "backspace merging paragraphs")
		try await host.waitForFreshPage()
		try await host.waitUntilReady()
		try await type("B1", after: "Still Top Secret", in: host)
	}

	@Test func backspaceIntoABoldParagraphEndIsSafelyBlocked() async throws {
		let host = try await makeHost()
		// The paragraph above "Any feedback" ends in bold, so the separator
		// slice is "**\n\n" — merging would eat the closing marker and
		// unbalance the markup. The edit must be rejected, the text left
		// untouched, and the editor must keep working after the resync.
		let before = host.text
		let caret = (host.text as NSString).range(of: "Any feedback").location
		// A nonce marks the current page; the rejection's resync reload drops
		// it, telling us deterministically when the fresh page is up.
		try await host.run("window.__testNonce = 1; window.__mdPlaceCaret(\(caret)); document.execCommand('delete');")
		try await host.waitForFreshPage()
		#expect(host.text == before)
		try await host.waitUntilReady()
		try await type("B2", after: "Any feedback", in: host)
	}

	// MARK: Steps

	/// Insert `marker` at the caret position derived from `anchor` in the
	/// host's *current* text, then require the host's text to become exactly
	/// the splice at that offset.
	private func type(_ marker: String, before anchor: String? = nil, after: String? = nil,
					  in host: EditorHost, sourceLocation: Testing.SourceLocation = #_sourceLocation) async throws {
		let ns = host.text as NSString
		let target = ns.range(of: (anchor ?? after)!)
		guard target.location != NSNotFound else {
			Issue.record("anchor \((anchor ?? after)!) not found", sourceLocation: sourceLocation)
			return
		}
		let offset = anchor != nil ? target.location : target.location + target.length
		let expected = ns.replacingCharacters(in: NSRange(location: offset, length: 0), with: marker)
		try await host.run("window.__mdPlaceCaret(\(offset)); document.execCommand('insertText', false, '\(marker)');")
		try await waitForText(expected, in: host, context: "typing \(marker) at offset \(offset)", sourceLocation: sourceLocation)
	}

	/// Place the caret at the start of `anchor` and press delete `count`
	/// times, removing the characters before it.
	private func deleteBackward(_ count: Int, endingAt anchor: String, in host: EditorHost,
								sourceLocation: Testing.SourceLocation = #_sourceLocation) async throws {
		let ns = host.text as NSString
		let target = ns.range(of: anchor)
		guard target.location != NSNotFound else {
			Issue.record("anchor \(anchor) not found", sourceLocation: sourceLocation)
			return
		}
		let expected = ns.replacingCharacters(in: NSRange(location: target.location - count, length: count), with: "")
		let deletes = Array(repeating: "document.execCommand('delete');", count: count).joined(separator: " ")
		try await host.run("window.__mdPlaceCaret(\(target.location)); \(deletes)")
		try await waitForText(expected, in: host, context: "deleting \(count) chars before \(anchor)", sourceLocation: sourceLocation)
	}

	private func waitForText(_ expected: String, in host: EditorHost, context: String,
							 sourceLocation: Testing.SourceLocation = #_sourceLocation) async throws {
		for _ in 0..<60 {
			if host.text == expected { return }
			try await Task.sleep(for: .milliseconds(50))
		}
		Issue.record("\(context): text never matched.\n\(firstDivergence(host.text, expected))", sourceLocation: sourceLocation)
	}

	/// Pinpoints where actual and expected first differ, for readable failures.
	private func firstDivergence(_ actual: String, _ expected: String) -> String {
		let a = Array(actual.utf16), e = Array(expected.utf16)
		let mismatch = (0..<min(a.count, e.count)).first { a[$0] != e[$0] } ?? min(a.count, e.count)
		let lo = max(0, mismatch - 30), hiA = min(a.count, mismatch + 30), hiE = min(e.count, mismatch + 30)
		let aCtx = String(decoding: a[lo..<hiA], as: UTF16.self).replacingOccurrences(of: "\n", with: "⏎")
		let eCtx = String(decoding: e[lo..<hiE], as: UTF16.self).replacingOccurrences(of: "\n", with: "⏎")
		return "diverges at utf16 offset \(mismatch)\nactual:   …\(aCtx)…\nexpected: …\(eCtx)…"
	}
}
#endif
