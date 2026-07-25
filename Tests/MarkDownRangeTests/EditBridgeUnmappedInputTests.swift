//
//  EditBridgeUnmappedInputTests.swift
//  MarkDownRangeTests
//
//  Editing commands the bridge deliberately does NOT map. The contract for
//  each is the same: the DOM mutation is blocked, the source is untouched, no
//  resync or hard rejection is recorded, and normal typing still works
//  afterwards. Several of these are gaps rather than policy (paste, soft line
//  breaks, list indent/outdent) — when one gets mapped, its test here should
//  become an assertion about the edit it produces.
//

#if os(macOS)
import AppKit
import Testing
@testable import MarkDownRange

@Suite(.serialized) @MainActor struct EditBridgeUnmappedInputTests {
	static let source = "alpha beta\n\n- one\n- two\n"

	/// Runs `command`, then checks the source never moved and the page is still
	/// healthy enough to take a real edit.
	private func expectNoOp(_ commands: [String], harness: CoordinatorBridgeHarness) async throws {
		try await harness.batch(commands)
		try await Task.sleep(for: .milliseconds(250))
		#expect(harness.source == Self.source)
		#expect(harness.sourceEditCount == 0)
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
		#expect(try await harness.stampMismatches() == [])
		// Still live: a mapped edit lands normally right after.
		try await harness.type("X", at: 1)
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "aXlpha beta\n\n- one\n- two\n")
	}

	@Test func webKitsOwnUndoIsBlockedSoTheHostOwnsHistory() async throws {
		let harness = try await CoordinatorBridgeHarness(source: Self.source)
		try await harness.type("X", at: 1)
		try await harness.waitForSourceEdits(1)
		let afterTyping = harness.source
		try await harness.run("document.execCommand('undo')")
		try await Task.sleep(for: .milliseconds(250))
		// The page must not roll its own DOM back: the host's source-level stack
		// is the only history, and a DOM-only undo would desync it.
		#expect(harness.source == afterTyping)
		#expect(harness.sourceEditCount == 1)
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
	}

	@Test func softLineBreakIsNotYetMapped() async throws {
		let harness = try await CoordinatorBridgeHarness(source: Self.source)
		try await expectNoOp([
			"window.__mdPlaceCaret(5)",
			"document.execCommand('insertLineBreak')",
		], harness: harness)
	}

	@Test func richInsertSplicesItsPlainTextIntoTheSource() async throws {
		// WebKit delivers execCommand('insertHTML') as insertText carrying its
		// payload on the dataTransfer (the same shape autocorrect uses), so the
		// bridge maps the plain text. The markup itself has no source form: the
		// DOM shows it as styled until the next re-render snaps it back.
		let harness = try await CoordinatorBridgeHarness(source: Self.source)
		try await harness.batch([
			"window.__mdPlaceCaret(5)",
			"document.execCommand('insertHTML', false, '<b>pasted</b>')",
		])
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "alphapasted beta\n\n- one\n- two\n")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func realPasteThroughWebKitIsNotYetMapped() async throws {
		// A genuine ⌘V: WebKit's own paste: action, driven from the pasteboard,
		// which arrives as inputType insertFromPaste. The bridge doesn't map
		// that, so the keystroke is dropped — pasting into the styled view does
		// nothing. Documented here (and asserted non-destructive) so that
		// implementing paste has a test to flip.
		let pasteboard = NSPasteboard.general
		let saved = pasteboard.string(forType: .string)
		defer {
			pasteboard.clearContents()
			if let saved { pasteboard.setString(saved, forType: .string) }
		}
		pasteboard.clearContents()
		pasteboard.setString("PASTED", forType: .string)

		let harness = try await CoordinatorBridgeHarness(source: Self.source)
		try await harness.placeCaret(5)
		harness.webView.window?.makeFirstResponder(harness.webView)
		harness.webView.perform(NSSelectorFromString("paste:"), with: nil)
		try await Task.sleep(for: .milliseconds(400))
		#expect(!harness.source.contains("PASTED"), "paste reached the source unexpectedly — map it and update this test")
		#expect(harness.source == Self.source)
		#expect(harness.coordinator.hardRejections == 0)
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func listIndentCommandIsNotYetMapped() async throws {
		let harness = try await CoordinatorBridgeHarness(source: Self.source)
		try await expectNoOp([
			"window.__mdPlaceCaret(16)",   // inside "one"
			"document.execCommand('indent')",
		], harness: harness)
	}

	@Test func typingInsideAFencedCodeBlockIsRefusedByTheReadOnlyIsland() async throws {
		// Code blocks are contentEditable=false islands: the caret can't land
		// inside, so no keystroke can splice into text whose DOM form isn't
		// verbatim source.
		let fenced = "text\n\n```\nlet x = 1\n```\n"
		let harness = try await CoordinatorBridgeHarness(source: fenced)
		#expect(try await harness.evaluate("document.querySelector('pre').contentEditable") == "false")
		try await harness.run("""
			var pre = document.querySelector('pre');
			var sel = window.getSelection(), r = document.createRange();
			r.selectNodeContents(pre); r.collapse(true);
			sel.removeAllRanges(); sel.addRange(r);
			document.execCommand('insertText', false, 'Z');
			""")
		try await Task.sleep(for: .milliseconds(250))
		#expect(harness.source == fenced)
		#expect(harness.coordinator.hardRejections == 0)
		#expect(try await harness.stampMismatches() == [])
	}
}
#endif
