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

	@Test func listIndentIsNotYetMapped() async throws {
		// Deliberately unmapped: indenting a list item correctly needs a rule
		// for the parent marker's width (bullets and ordered items differ), so
		// the command is dropped rather than guessed at.
		let harness = try await CoordinatorBridgeHarness(source: Self.source)
		try await expectNoOp([
			"window.__mdPlaceCaret(16)",   // inside "one"
			"document.execCommand('indent')",
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

	@Test func typingInsideAFencedCodeBlockSplicesTheVerbatimSource() async throws {
		let fenced = "text\n\n```\nlet x = 1\n```\n"
		let harness = try await CoordinatorBridgeHarness(source: fenced)
		#expect(try await harness.evaluate("document.querySelector('pre').contentEditable") != "false")
		try await harness.type("Z", at: 13)
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "text\n\n```\nletZ x = 1\n```\n")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func typingIntoAnEmptyFencedCodeBlockCreatesItsFirstCharacter() async throws {
		let fenced = "```\n\n```\n"
		let harness = try await CoordinatorBridgeHarness(source: fenced)
		try await harness.type("X", at: 4)
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "```\nX\n```\n")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func returnInsideAFencedCodeBlockInsertsASourceNewline() async throws {
		let fenced = "```swift\nlet value = 1\n```\n"
		let harness = try await CoordinatorBridgeHarness(source: fenced)
		try await harness.batch([
			"window.__mdPlaceCaret(14)",
			"document.execCommand('insertParagraph')",
		])
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "```swift\nlet v\nalue = 1\n```\n")
		try await harness.waitQuiescent()
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
		#expect(try await harness.stampMismatches() == [])
	}
}
#endif
