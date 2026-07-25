//
//  EditBridgeHardBreakTests.swift
//  MarkDownRangeTests
//
//  Shift-Enter in the styled editor. A hard break is written as a backslash
//  break rather than two trailing spaces: invisible trailing whitespace makes
//  the run it ends non-verbatim, which costs that run its data-s stamp and
//  leaves the text uneditable. The splice also takes the following line's
//  leading whitespace with it, since the renderer strips it.
//

#if os(macOS)
import AppKit
import Testing
@testable import MarkDownRange

@Suite(.serialized) @MainActor struct EditBridgeHardBreakTests {

	@Test func shiftEnterInsertsABackslashHardBreak() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "one two\n")
		try await harness.batch([
			"window.__mdPlaceCaret(3)",
			"document.execCommand('insertLineBreak')",
		])
		try await harness.waitForSourceEdits(1)
		// Backslash form, not two trailing spaces: invisible whitespace would
		// cost the run it ends its data-s stamp and make that text uneditable.
		#expect(harness.source == "one\\\ntwo\n")
		try await harness.waitQuiescent()
		#expect(try await harness.evaluate("String(document.querySelectorAll('br').length)") == "1")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func typingStillWorksOnBothSidesOfAHardBreak() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "one two\n")
		try await harness.batch([
			"window.__mdPlaceCaret(3)",
			"document.execCommand('insertLineBreak')",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		try await harness.type("A", at: 2)          // before the break
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == "onAe\\\ntwo\n")
		#expect(try await harness.stampMismatches() == [])

		try await harness.type("B", at: 6)          // after the break
		try await harness.waitForSourceEdits(3)
		#expect(harness.source == "onAe\\\nBtwo\n")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
	}

	@Test func shiftEnterInsideATableCellIsRefused() async throws {
		let table = "| a | b |\n| --- | --- |\n| c | d |"
		let harness = try await CoordinatorBridgeHarness(source: table)
		try await harness.batch([
			"window.__mdPlaceCaret(\((table as NSString).range(of: "c").location + 1))",
			"document.execCommand('insertLineBreak')",
		])
		try await Task.sleep(for: .milliseconds(300))
		#expect(harness.source == table)
		#expect(harness.sourceEditCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
		#expect(try await harness.stampMismatches() == [])
	}
}
#endif
