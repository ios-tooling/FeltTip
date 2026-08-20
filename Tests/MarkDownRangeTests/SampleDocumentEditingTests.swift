#if os(macOS)
	import AppKit
#else
	import UIKit
#endif
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
	private let host: TestWindowHost

	init(text: String) {
		self.text = text
		let config = WKWebViewConfiguration()
		webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 700, height: 900), configuration: config)
		coordinator = MarkdownWebView.Coordinator(parent: MarkdownWebView(text: text, theme: .default, fontSize: 16).editable(true))
		host = TestWindowHost(view: webView)
		super.init()
		config.userContentController.add(self, name: "mdedit")
		webView.navigationDelegate = coordinator
		coordinator.webView = webView
		updateParent()
		coordinator.load(into: webView)
	}

	/// An external text change (e.g. the raw pane of a split editing the same
	/// document): new text arrives from outside the web view's own bridge.
	func replaceTextExternally(_ new: String) {
		text = new
		updateParent()
		coordinator.load(into: webView)
	}

	/// Mirrors `updateNSView`: a source edit updates the host's text, which
	/// hands the coordinator a fresh parent value and re-runs `load`.
	private func updateParent() {
		coordinator.parent = MarkdownWebView(text: text, theme: .default, fontSize: 16)
			.editable(true)
			.onSourceEdit { [weak self] new, _ in
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

	/// Waits until a structural edit has fully landed. Structural edits patch
	/// the page in place now (no navigation), so "fresh" means: the page is
	/// not frozen — the edit froze it synchronously in its own turn — and it
	/// addresses the coordinator's current revision.
	func waitForFreshPage() async throws {
		for _ in 0..<100 {
			let state = try await evaluate("""
				(window.__mdIsFrozen && window.__mdIsFrozen()) ? 'frozen'
					: (window.__mdGetRev ? String(window.__mdGetRev()) : 'none')
				""")
			if state == String(coordinator.currentRev) { return }
			try await Task.sleep(for: .milliseconds(50))
		}
		Issue.record("page never settled after structural edit")
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

	@Test func enterAtParagraphEndKeepsTheCaretUsable() async throws {
		// Return splices "\n\n" and re-renders; the caret offset lands in an
		// empty paragraph markdown renders NO text for. Without a synthesized
		// placeholder run the caret was dropped and the page sat at the top —
		// and the next keystroke had nowhere to map.
		let host = EditorHost(text: "Alpha\n\nBeta")
		try await host.waitUntilReady()
		try await host.run("window.__testNonce = 1; window.__mdPlaceCaret(5); document.execCommand('insertParagraph');")
		try await waitForText("Alpha\n\n\n\nBeta", in: host, context: "enter at paragraph end")
		try await host.waitForFreshPage()
		try await host.waitUntilReady()
		// The placeholder run must exist at the caret offset, and typing into
		// it must splice into the new empty paragraph.
		let holder = try await host.evaluate("document.querySelector('[data-s=\"7\"]') ? 'yes' : 'no'")
		#expect(holder == "yes", "no caret placeholder for the empty paragraph")
		try await host.run("document.execCommand('insertText', false, 'X')")
		try await waitForText("Alpha\n\nX\n\nBeta", in: host, context: "typing into the new paragraph")
	}

	@Test func backspaceAfterEnterRemovesTheNewLine() async throws {
		// Return creates an empty paragraph (with a synthesized caret
		// placeholder); Backspace right after must undo it, merging back to
		// the original source.
		let host = EditorHost(text: "Alpha\n\nBeta")
		try await host.waitUntilReady()
		try await host.run("window.__testNonce = 1; window.__mdPlaceCaret(5); document.execCommand('insertParagraph');")
		try await waitForText("Alpha\n\n\n\nBeta", in: host, context: "enter at paragraph end")
		try await host.waitForFreshPage()
		try await host.waitUntilReady()
		try await host.run("document.execCommand('delete');")
		try await waitForText("Alpha\n\nBeta", in: host, context: "backspace undoing the enter")
	}


	@Test func styleToggleKeepsTheSelection() async throws {
		// After ⌘B the same text stays selected (shifted past the new
		// markers), so repeated style commands keep operating on it.
		let host = EditorHost(text: "Alpha\n\nBeta")
		try await host.waitUntilReady()
		try await host.run("""
			window.__testNonce = 1;
			window.__mdPlaceCaret(5);
			var sel = window.getSelection();
			for (var i = 0; i < 5; i++) sel.modify('extend', 'backward', 'character');
			document.execCommand('bold');
			""")
		try await waitForText("**Alpha**\n\nBeta", in: host, context: "bold via command")
		try await host.waitForFreshPage()
		try await host.waitUntilReady()
		try await Task.sleep(for: .milliseconds(400))   // selection restore runs after layout settles
		let selected = try await host.evaluate("window.getSelection().toString()")
		#expect(selected == "Alpha", "selection not preserved after bold (got \(selected ?? "nil"))")
	}

	@Test func enterKeepsTheScrollPosition() async throws {
		// Return re-renders the page; the view must come back to where the
		// user was, not to the top and not with the caret parked at the
		// bottom edge of the viewport.
		let host = try await makeHost()
		let ns = host.text as NSString
		let caret = ns.range(of: "stay a surprise").location
		// Scroll so the caret sits comfortably mid-viewport. Layout metrics
		// vary run to run, so derive the position from the caret's own run —
		// a fixed offset sometimes left the caret off-screen, where a
		// (correct) minimal nudge would fail the equality check.
		let target = try await host.evaluate("""
			(function () {
			  var spans = document.querySelectorAll('[data-s]');
			  for (var i = 0; i < spans.length; i++) {
			    var base = parseInt(spans[i].getAttribute('data-s'), 10);
			    if (base <= \(caret) && \(caret) <= base + spans[i].textContent.length) {
			      var y = Math.max(0, Math.round(spans[i].getBoundingClientRect().top + window.scrollY - 300));
			      window.scrollTo(0, y);
			      return String(Math.round(window.scrollY));   // the ACHIEVED position (clamped to maxY)
			    }
			  }
			  return "-1";
			})()
			""").flatMap { Double($0) } ?? -1
		#expect(target > 0, "couldn't derive a scroll target")
		// The page reports scroll positions through a rAF throttle that
		// doesn't reliably run headless; seed the tracked position directly.
		host.coordinator.lastScrollY = target
		let expected = ns.replacingCharacters(in: NSRange(location: caret, length: 0), with: "\n\n")
		try await host.run("window.__testNonce = 1; window.__mdPlaceCaret(\(caret)); document.execCommand('insertParagraph');")
		try await waitForText(expected, in: host, context: "enter mid-document")
		try await host.waitForFreshPage()
		try await host.waitUntilReady()
		try await Task.sleep(for: .milliseconds(400))   // let the restore land
		let scrollY = try await host.evaluate("String(Math.round(window.scrollY))").flatMap { Double($0) } ?? -1
		#expect(abs(scrollY - target) < 60, "scroll moved from \(target) to \(scrollY) after Return")
	}

	@Test func sourceOffsetScrollTargetsTheHeading() async throws {
		// Outline navigation: a heading's source offset scrolls its run into
		// view, even though the offset points at the "#" markers themselves.
		let host = try await makeHost()
		let offset = (host.text as NSString).range(of: "### Loose lips").location
		try await host.run("window.__mdScrollToSourceOffset(\(offset))")
		try await Task.sleep(for: .milliseconds(200))
		let scrollY = try await host.evaluate("String(Math.round(window.scrollY))").flatMap { Double($0) } ?? -1
		#expect(scrollY > 200, "outline scroll did not move the view (scrollY \(scrollY))")
	}

	@Test func externalTextChangeSwapsContentWithoutNavigating() async throws {
		// Typing in the raw pane re-renders the preview; that must be an
		// in-place body swap (no navigation, no flash, scroll kept). A page
		// nonce survives a swap but not a reload.
		let host = try await makeHost()
		try await host.run("window.__testNonce = 1")
		host.replaceTextExternally(host.text.replacingOccurrences(of: "polish, resilience", with: "polish, MAGIC, resilience"))
		try await host.waitUntilReady(domContains: "MAGIC")
		let nonce = try await host.evaluate("typeof window.__testNonce === 'number' ? 'alive' : 'gone'")
		#expect(nonce == "alive", "external text update navigated instead of swapping in place")
		// The swapped DOM carries fresh stamps and live listeners: editing
		// must keep working, splicing at the right spot in the new text.
		try await type("SW", after: "MAGIC", in: host)
	}

	@Test func backspaceIntoABoldParagraphEndIsSafelyBlocked() async throws {
		let host = try await makeHost()
		// The paragraph above "Any feedback" ends in bold, so the separator
		// slice is "**\n\n" — merging would eat the closing marker and
		// unbalance the markup. The edit must be vetoed with the text left
		// untouched — and because the page prevented the DOM mutation, the
		// veto needs NO resync reload: the page thaws in place (the nonce
		// survives) and typing keeps working immediately.
		let before = host.text
		let caret = (host.text as NSString).range(of: "Any feedback").location
		try await host.run("window.__testNonce = 1; window.__mdPlaceCaret(\(caret)); document.execCommand('delete');")
		try await Task.sleep(for: .milliseconds(400))
		#expect(host.text == before)
		let nonce = try await host.evaluate("typeof window.__testNonce === 'number' ? 'alive' : 'gone'")
		#expect(nonce == "alive", "a veto must thaw in place, not reload the page")
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
