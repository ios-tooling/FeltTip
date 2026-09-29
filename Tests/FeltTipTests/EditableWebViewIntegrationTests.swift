#if os(macOS)
	import AppKit
#else
	import UIKit
#endif
import Testing
import WebKit
@testable import FeltTip

/// Drives the real editor script in a live WKWebView: `execCommand` fires the
/// same `beforeinput`/`input` pipeline as typing, and the harness plays the
/// Coordinator's role (splice via `MarkdownEditSplicer`). This covers the bug
/// class the bridge exists to prevent: an edit in one paragraph must not make
/// a later edit splice from stale offsets.
@MainActor
private final class EditBridgeHarness: NSObject, WKScriptMessageHandler {
	var source: String
	var rejections: [String] = []
	var editCount = 0

	init(source: String) { self.source = source }

	func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
		guard let body = message.body as? [String: Any] else { return }
		guard body["type"] == nil else { return }   // ready / scroll / error
		editCount += 1
		guard let edit = MarkdownEditSplicer.Edit(body: body) else { return }
		switch MarkdownEditSplicer.apply(edit, to: source) {
		case .applied(let new, _, _): source = new
		case .rejected(let reason): rejections.append(reason)
		}
	}
}

@Suite(.serialized) @MainActor struct EditableWebViewIntegrationTests {
	@Test func editsInTwoParagraphsSpliceAtFreshOffsets() async throws {
		let harness = EditBridgeHarness(source: "Alpha\n\nBeta")
		let webView = try await makeEditableWebView(harness: harness)

		// Type "X" at the end of "Alpha" — every later run's true offset shifts.
		try await run(webView, "window.__mdPlaceCaret(5); document.execCommand('insertText', false, 'X');")
		try await waitForEdits(1, in: harness)
		#expect(harness.source == "AlphaX\n\nBeta")

		// The page must have shifted Beta's stamp from 7 to 8 on its own.
		let stamps = try await evaluate(webView, "Array.from(document.querySelectorAll('[data-s]')).map(e => e.getAttribute('data-s')).join(',')")
		#expect(stamps == "0,8")

		// Typing at the start of "Beta" must land before the B, not inside the
		// paragraph separator (the pre-fix corruption).
		try await run(webView, "window.__mdPlaceCaret(8); document.execCommand('insertText', false, 'Y');")
		try await waitForEdits(2, in: harness)
		#expect(harness.source == "AlphaX\n\nYBeta")

		// And a delete still verifies the replaced text against fresh offsets.
		try await run(webView, "window.__mdPlaceCaret(10); document.execCommand('delete');")
		try await waitForEdits(3, in: harness)
		#expect(harness.source == "AlphaX\n\nYeta")
		#expect(harness.rejections.isEmpty)
	}

	@Test func webKitWhitespaceMunglingDoesNotRejectTheNextEdit() async throws {
		// The field-reported bug: WebKit swaps spaces to non-breaking spaces
		// around every insertion, so the next keystroke's context contained
		// U+00A0s the source doesn't have and got rejected — eating every
		// other typed character. Reproduce the swap and keep typing.
		let harness = try await CoordinatorBridgeHarness(
			source: "Alpha and     more\n\nBeta")
		try await harness.run("""
			window.__mdPlaceCaret(9);
			document.execCommand('insertText', false, 'X');
			""")
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		#expect(harness.source == "Alpha andX     more\n\nBeta")

		// Mangle the freshly rendered page, then re-place the caret (mutating
		// nodeValue resets the selection) and type into that whitespace context.
		try await harness.run("""
			var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
			var n; while ((n = walker.nextNode())) { n.nodeValue = n.nodeValue.replace(/ {2}/g, ' \\u00A0'); }
			window.__mdPlaceCaret(10);
			document.execCommand('insertText', false, 'Y');
			""")
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()
		#expect(harness.source == "Alpha andXY     more\n\nBeta")
		#expect(harness.coordinator.hardRejections == 0)
		#expect(harness.coordinator.resyncCount == 0)
	}

	@Test func boldCommandWrapsTheSelection() async throws {
		// ⌘B in the styled editor runs WebKit's bold command; the bridge's
		// formatBold path must wrap the verified selection in markers.
		let harness = EditBridgeHarness(source: "Alpha\n\nBeta")
		let webView = try await makeEditableWebView(harness: harness)
		try await run(webView, """
			window.__mdPlaceCaret(5);
			var sel = window.getSelection();
			for (var i = 0; i < 5; i++) sel.modify('extend', 'backward', 'character');
			document.execCommand('bold');
			""")
		try await waitForEdits(1, in: harness)
		#expect(harness.source == "**Alpha**\n\nBeta")
		#expect(harness.rejections.isEmpty)
	}

	@Test func strikethroughCommandWrapsTheSelection() async throws {
		// ⌘⇧X runs WebKit's strikeThrough command; the bridge's
		// formatStrikeThrough path wraps the verified selection in `~~`.
		let harness = EditBridgeHarness(source: "Alpha\n\nBeta")
		let webView = try await makeEditableWebView(harness: harness)
		try await run(webView, """
			window.__mdPlaceCaret(5);
			var sel = window.getSelection();
			for (var i = 0; i < 5; i++) sel.modify('extend', 'backward', 'character');
			document.execCommand('strikeThrough');
			""")
		try await waitForEdits(1, in: harness)
		#expect(harness.source == "~~Alpha~~\n\nBeta")
		#expect(harness.rejections.isEmpty)
	}

	@Test func boldCommandTogglesOffBoldText() async throws {
		// Selecting already-bold text and hitting ⌘B removes the markers.
		let harness = EditBridgeHarness(source: "**Alpha**\n\nBeta")
		let webView = try await makeEditableWebView(harness: harness)
		try await run(webView, """
			window.__mdPlaceCaret(7);
			var sel = window.getSelection();
			for (var i = 0; i < 5; i++) sel.modify('extend', 'backward', 'character');
			document.execCommand('bold');
			""")
		try await waitForEdits(1, in: harness)
		#expect(harness.source == "Alpha\n\nBeta")
		#expect(harness.rejections.isEmpty)
	}

	@Test func mirroredSelectionHighlightsWithoutSelecting() async throws {
		// The other pane's selection shows as a CSS highlight overlay; the
		// page's own selection must stay untouched.
		let harness = EditBridgeHarness(source: "Alpha\n\nBeta")
		let webView = try await makeEditableWebView(harness: harness)
		try await run(webView, "window.__mdMirrorSelection(0, 5)")
		let highlighted = try await evaluate(webView, "CSS.highlights.has('md-mirror') ? 'yes' : 'no'")
		#expect(highlighted == "yes")
		let ownSelection = try await evaluate(webView, "window.getSelection().toString()")
		#expect(ownSelection == "", "mirror must not touch the real selection")
		// A new mirror replaces the old one — never accumulates.
		try await run(webView, "window.__mdMirrorSelection(7, 4)")
		let count = try await evaluate(webView, "String(CSS.highlights.get('md-mirror').size)")
		#expect(count == "1", "mirror accumulated ranges: \(count ?? "nil")")
		// Applying a mirror while unfocused clears any leftover real
		// selection, so the pane never shows two apparent selections.
		try await run(webView, """
			var r = document.createRange();
			var span = document.querySelector('[data-s]');
			r.selectNodeContents(span);
			var sel = window.getSelection(); sel.removeAllRanges(); sel.addRange(r);
			window.__mdMirrorSelection(7, 4);
			""")
		let realSel = try await evaluate(webView, "window.getSelection().toString()")
		#expect(realSel == "", "stale real selection persisted alongside the mirror")
		try await run(webView, "window.__mdMirrorSelection(null, 0)")
		let cleared = try await evaluate(webView, "CSS.highlights.has('md-mirror') ? 'yes' : 'no'")
		#expect(cleared == "no")
	}

	@Test func focusModeTracksTheBlockContainingTheCaret() async throws {
		let harness = EditBridgeHarness(source: "Alpha\n\nBeta")
		let webView = try await makeEditableWebView(harness: harness)
		try await run(webView, MarkdownWebView.Coordinator.focusModeScript)
		try await run(webView, "window.__mdSetFocusMode(true)")
		let inactive = try await evaluate(webView, "document.body.classList.contains('md-focus-mode') ? 'dimmed' : 'normal'")
		#expect(inactive == "normal", "an inactive split pane must not be dimmed wholesale")

		#if os(macOS)
			webView.window?.makeKey()
		#endif
		try await run(webView, "window.__mdPlaceCaret(8);")
		try await Task.sleep(for: .milliseconds(50))

		let state = try await evaluate(webView, """
			(document.body.classList.contains('md-focus-mode') ? 'on:' : 'off:') +
			Array.from(document.body.children)
			  .filter(e => e.matches('p'))
			  .map(e => e.classList.contains('md-focus-active') ? 'active' : 'inactive')
			  .join(',')
			""")
		#expect(state == "on:inactive,active")

		try await run(webView, "window.__mdSetFocusMode(false)")
		let restored = try await evaluate(webView, "document.body.classList.contains('md-focus-mode') ? 'on' : 'off'")
		#expect(restored == "off")
	}

	@Test func footnoteLinksNavigateInsideEditableDocument() async throws {
		let filler = (1...80)
			.map { "Paragraph \($0): enough text to require scrolling." }
			.joined(separator: "\n\n")
		let source = """
		# Footnotes

		Jump to the note.[^deploy]

		\(filler)

		[^deploy]: Deployment details.
		"""
		let harness = try await CoordinatorBridgeHarness(source: source)

		try await harness.run("""
			var reference = document.querySelector('a[href="#feltip-footnote-deploy"]');
			reference.dispatchEvent(new MouseEvent('mousedown', {
			  bubbles: true, cancelable: true, button: 0
			}));
			""")
		let atNote = Int(try await harness.evaluate("String(Math.round(window.scrollY))") ?? "0") ?? 0
		#expect(atNote > 500)

		try await harness.run("""
			var back = document.querySelector('a[href="#feltip-footnote-ref-deploy"]');
			back.dispatchEvent(new MouseEvent('mousedown', {
			  bubbles: true, cancelable: true, button: 0
			}));
			""")
		let atReference = Int(try await harness.evaluate("String(Math.round(window.scrollY))") ?? "9999") ?? 9999
		#expect(atReference < 200)
	}

	@Test func repeatedFootnoteBacklinkReturnsToActivatedOccurrence() async throws {
		let firstFiller = (1...35).map { "First section \($0)." }.joined(separator: "\n\n")
		let secondFiller = (1...35).map { "Second section \($0)." }.joined(separator: "\n\n")
		let source = """
		First occurrence.[^shared]

		\(firstFiller)

		Second occurrence.[^shared]

		\(secondFiller)

		[^shared]: Shared details.
		"""
		let harness = try await CoordinatorBridgeHarness(source: source)

		try await harness.run("""
			var references = document.querySelectorAll('a[href="#feltip-footnote-shared"]');
			references[1].dispatchEvent(new MouseEvent('mousedown', {
			  bubbles: true, cancelable: true, button: 0
			}));
			""")
		let atNote = Int(try await harness.evaluate("String(Math.round(window.scrollY))") ?? "0") ?? 0
		#expect(atNote > 1_000)

		try await harness.run("""
			var back = document.querySelector('a[href="#feltip-footnote-ref-shared"]');
			back.dispatchEvent(new MouseEvent('mousedown', {
			  bubbles: true, cancelable: true, button: 0
			}));
			""")
		let atSecondReference = Int(
			try await harness.evaluate("String(Math.round(window.scrollY))") ?? "0") ?? 0
		#expect(atSecondReference > 500)
		#expect(atSecondReference < atNote)
	}

	@Test func compositionReconcilesTheWholeRunAtOnce() async throws {
		// The inline-predictive-text scenario: while a composition is live,
		// plain keystrokes still arrive as ordinary insertText events, but
		// their offsets are tainted by marked text the source doesn't have.
		// The bridge must NOT map them individually — it snapshots the run at
		// compositionstart and posts one verified replacement at
		// compositionend covering everything that happened in between.
		let harness = EditBridgeHarness(source: "Alpha\n\nBeta")
		let webView = try await makeEditableWebView(harness: harness)

		try await run(webView, """
			window.__mdPlaceCaret(5);
			document.body.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
			document.execCommand('insertText', false, 'X');
			document.execCommand('insertText', false, 'é');
			document.body.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: 'Xé' }));
			""")
		try await waitForEdits(1, in: harness)
		#expect(harness.source == "AlphaXé\n\nBeta")
		#expect(harness.editCount == 1, "per-keystroke events during composition must not post individually")

		// Composition commits freeze for a structural refresh: a whole-run
		// replacement can change Markdown interpretation, which this script-only
		// seam cannot safely restamp without the real coordinator/render loop.
		#expect(try await evaluate(webView, "window.__mdIsFrozen() ? 'yes' : 'no'") == "yes")
		#expect(harness.rejections.isEmpty)
	}

	// MARK: Plumbing

	private func makeEditableWebView(harness: EditBridgeHarness) async throws -> WKWebView {
		let config = WKWebViewConfiguration()
		config.userContentController.add(harness, name: "mdedit")
		let webView = WKWebView(
			frame: CGRect(x: 0, y: 0, width: 600, height: 400), configuration: config)
		let host = TestWindowHost(view: webView)
		let html = MarkdownHTMLRenderer.renderDocument(markdown: harness.source, includeSourceOffsets: true)
		webView.loadHTMLString(html, baseURL: nil)
		// readyState alone is useless here: the initial about:blank page is
		// already "complete", and injecting there gets wiped by the navigation.
		try await waitUntil("stamped content") {
			try await self.evaluate(webView, "document.querySelector('[data-s]') ? 'yes' : 'no'") == "yes"
		}
		try await run(webView, MarkdownWebView.Coordinator.editorScript)
		return webView
	}

	/// The async `evaluateJavaScript` traps on statements that produce no
	/// serializable value, so both helpers go through the callback variant
	/// (and return only strings, which cross isolation safely).
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

	private func waitForEdits(_ count: Int, in harness: EditBridgeHarness) async throws {
		try await waitUntil("edit \(count)") { harness.editCount >= count }
	}

	private func waitUntil(_ label: String, _ condition: () async throws -> Bool) async throws {
		for _ in 0..<100 {
			if try await condition() { return }
			try await Task.sleep(for: .milliseconds(50))
		}
		Issue.record("timed out waiting for \(label)")
	}
}
