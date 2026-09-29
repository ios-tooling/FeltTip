//
//  EditBridgeCaretRestoreRaceTests.swift
//  FeltTipTests
//
//  A host-driven caret restore (undo / redo) re-renders the page without
//  freezing it, and the re-render is async. Until it lands the DOM still shows
//  the PREVIOUS content — so a keystroke in that window used to arrive at a
//  matching revision and splice into the pre-restore source, handing the undone
//  text straight back to the host. Closing the revision epoch when the patch is
//  scheduled makes those stragglers pre-reseed: dropped, never applied.
//

import Testing
import WebKit
@testable import FeltTip

@Suite(.serialized) @MainActor struct EditBridgeCaretRestoreRaceTests {
	/// Emulates the host restoring `text` (an undo) with a caret target, exactly
	/// as updateNSView does: swap the parent, arm the caret, then load.
	private func restore(_ text: String, caret: Int, token: Int, in harness: CoordinatorBridgeHarness) {
		harness.focusWebView()
		harness.coordinator.parent = MarkdownWebView(text: text, theme: .default, fontSize: 14)
			.editable(true)
			.caretTarget(MarkdownCaretTarget(offset: caret, token: token))
			.onSourceEdit { [weak harness] newText, _ in harness?.recordExternalEdit(newText) }
		harness.coordinator.applyCaretTarget()
		harness.coordinator.load(into: harness.webView)
		harness.adoptHostText(text)
	}

	@Test func aKeystrokeDuringARestoreCannotResurrectTheUndoneText() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "alpha beta\n")
		try await harness.type("X", at: 5)
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "alphaX beta\n")
		try await harness.waitQuiescent()

		// Undo: the host restores the earlier text with a caret target...
		restore("alpha beta\n", caret: 5, token: 1, in: harness)
		// ...and the user types immediately, while the old DOM is still up.
		try await harness.run("document.execCommand('insertText', false, 'Z')")
		try await Task.sleep(for: .milliseconds(600))

		// Whatever happened to the keystroke, the undone "X" must not come back.
		#expect(!harness.source.contains("X"), "the undone edit was spliced back in")
		#expect(harness.coordinator.hardRejections == 0)
		try await harness.waitQuiescent()
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func aRestoreLeavesThePageAtTheHostsRevision() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "alpha beta\n")
		try await harness.type("X", at: 5)
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		restore("alpha beta\n", caret: 5, token: 1, in: harness)
		try await harness.waitQuiescent()
		// The page addresses the revision the coordinator believes in, and shows
		// the restored text.
		let pageRev = try await harness.evaluate("String(window.__mdGetRev())")
		#expect(pageRev == String(harness.coordinator.currentRev))
		#expect(harness.coordinator.currentSource == "alpha beta\n")
		#expect(try await harness.evaluate("document.body.textContent.indexOf('X') >= 0 ? 'yes' : 'no'") == "no")
	}

	@Test func typingResumesNormallyAfterARestoreSettles() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "alpha beta\n")
		try await harness.type("X", at: 5)
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		restore("alpha beta\n", caret: 5, token: 1, in: harness)
		try await harness.waitQuiescent()
		harness.rewireRoundTrip()

		let editsBefore = harness.sourceEditCount
		try await harness.type("Q", at: 5)
		try await harness.waitForSourceEdits(editsBefore + 1)
		#expect(harness.source == "alphaQ beta\n")
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func restoringCaretInsideTaskMarkerDoesNotInsertAListGap() async throws {
		let source = "- [x] existing task\n- [ ] pending task\n"
		let checkbox = (source as NSString).range(of: "[ ]")
		let caret = checkbox.location + 1
		let harness = try await CoordinatorBridgeHarness(source: source)

		restore(source, caret: caret, token: 1, in: harness)
		try await harness.waitQuiescent()

		let syntheticParagraphs = try await harness.evaluate(
			"String(document.querySelectorAll('ul > p, ol > p').length)")
		#expect(syntheticParagraphs == "0")
		let caretItem = try await harness.evaluate("""
			(() => {
			  const selection = window.getSelection();
			  const node = selection && selection.anchorNode;
			  const element = node && node.nodeType === 1 ? node : node && node.parentElement;
			  const item = element && element.closest ? element.closest('li') : null;
			  return item ? item.textContent.trim() : '';
			})()
			""")
		#expect(caretItem == "pending task")
	}

	@Test(arguments: [
		("Plain alpha omega", "alpha", "alpha"),
		("Before **bold** after", "bold", "bold"),
		("Before **bold** after", "ld", "ld"),
		("Before **bold** after", "bold", ""),
		("Intro\n\n**Chosen paragraph.**\n\nTail", "Chosen paragraph.", "Chosen paragraph."),
		("A 🙂 emoji and é tail", "🙂 emoji", "🙂 emoji"),
		("- **Item one**\n- Item two", "Item one", "Item one"),
		("one\\\ntwo **bold**", "two", "two "),
	])
	func deletingThenRestoringMajorSelectionShapesRemainsEditable(
		source: String,
		selectionStart: String,
		selectionEnd: String
	) async throws {
		let nsSource = source as NSString
		let start = nsSource.range(of: selectionStart).location
		let end = selectionEnd.isEmpty
			? nsSource.length
			: nsSource.range(of: selectionEnd).upperBound
		let selected = NSRange(location: start, length: end - start)
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.batch([
			"window.__mdPlaceCaret(\(selected.location), \(selected.length))",
			"document.execCommand('delete')",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		#expect(harness.source != source)
		#expect(try await harness.stampMismatches() == [])

		restore(source, caret: selected.location, token: 1, in: harness)
		try await harness.waitQuiescent()
		#expect(harness.source == source)
		#expect(try await harness.stampMismatches() == [])
		harness.rewireRoundTrip()

		let editsBefore = harness.sourceEditCount
		try await harness.type("Q")
		try await harness.waitForSourceEdits(editsBefore + 1)
		try await harness.waitQuiescent()
		let fresh = try await CoordinatorBridgeHarness(source: harness.source)
		let liveText = EditBridgeFuzzTests.normalizedVisibleText(try await harness.domVisibleText())
		let freshText = EditBridgeFuzzTests.normalizedVisibleText(try await fresh.domVisibleText())
		#expect(liveText == freshText)
		#expect(try await harness.stampMismatches() == [])
		#expect(
			harness.coordinator.resyncCount == 0,
			"unexpected bridge recovery: \(harness.coordinator.lastResyncReason ?? String(describing: harness.coordinator.bridgeIncidents))"
		)
		#expect(harness.coordinator.hardRejections == 0)
	}
}
