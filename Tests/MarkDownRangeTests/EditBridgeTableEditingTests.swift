//
//  EditBridgeTableEditingTests.swift
//  MarkDownRangeTests
//
//  Editing inside table cells. Cell runs carry data-s stamps like any
//  paragraph, so in-place edits splice between the pipes; the structural
//  hazards are what these tests police — Enter mid-row is swallowed, and a
//  backspace at a cell boundary must never eat the pipe syntax.
//

#if os(macOS)
import Testing
@testable import MarkDownRange

@Suite(.serialized) @MainActor struct EditBridgeTableEditingTests {
	static let table = "| Name | Age |\n| --- | --- |\n| Alice | 30 |\n| **Bob** | 41 |"

	@Test func typingInBodyCellSplicesBetweenPipes() async throws {
		let harness = try await CoordinatorBridgeHarness(source: Self.table)
		try await harness.type("X", at: 33)   // Al|ice
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "| Name | Age |\n| --- | --- |\n| AlXice | 30 |\n| **Bob** | 41 |")
		#expect(harness.lastCaretHint == 34)
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func typingInHeaderCellSplicesBetweenPipes() async throws {
		let harness = try await CoordinatorBridgeHarness(source: Self.table)
		try await harness.type("X", at: 6)   // Name|
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "| NameX | Age |\n| --- | --- |\n| Alice | 30 |\n| **Bob** | 41 |")
		#expect(harness.coordinator.resyncCount == 0)
	}

	@Test func typingInStyledCellKeepsMarkers() async throws {
		let harness = try await CoordinatorBridgeHarness(source: Self.table)
		try await harness.type("X", at: 49)   // **B|ob**
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "| Name | Age |\n| --- | --- |\n| Alice | 30 |\n| **BXob** | 41 |")
		#expect(harness.coordinator.resyncCount == 0)
	}

	@Test func enterInCellNeverSplicesAParagraphBreak() async throws {
		// Enter navigates (next row) or appends a row (last row) — it must
		// never splice a "\n\n" paragraph break into the table itself. From a
		// mid-table cell it is a pure caret move: zero source edits.
		let harness = try await CoordinatorBridgeHarness(source: Self.table)
		try await harness.batch([
			"window.__mdPlaceCaret(33)",
			"document.execCommand('insertParagraph')",
		])
		try await Task.sleep(for: .milliseconds(300))
		#expect(harness.source == Self.table)
		#expect(harness.sourceEditCount == 0)
		#expect(harness.coordinator.resyncCount == 0)
	}

	@Test func typingIntoEmptyCellSplicesBetweenItsPipes() async throws {
		// The empty Age cell renders a stamped, text-less caret home; typing
		// there must splice inside ITS pipes, padded like a hand-written cell.
		let harness = try await CoordinatorBridgeHarness(source: "| Name | Age |\n| --- | --- |\n| Alice |  |")
		try await harness.type("X", at: 39)
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "| Name | Age |\n| --- | --- |\n| Alice | X |")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	static let plainTable = "| Name | Age |\n| --- | --- |\n| Alice | 30 |\n| Bob | 41 |"

	@Test func enterMovesToSameColumnInNextRow() async throws {
		let harness = try await CoordinatorBridgeHarness(source: Self.plainTable)
		try await harness.batch([
			"window.__mdPlaceCaret(33)",   // inside Alice (column 0)
			"document.execCommand('insertParagraph')",
			"document.execCommand('insertText', false, 'Q')",
		])
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "| Name | Age |\n| --- | --- |\n| Alice | 30 |\n| BobQ | 41 |")
		#expect(harness.coordinator.resyncCount == 0)
	}

	@Test func enterMovesFromHeaderIntoFirstBodyRow() async throws {
		let harness = try await CoordinatorBridgeHarness(source: Self.plainTable)
		try await harness.batch([
			"window.__mdPlaceCaret(4)",    // inside Name (header, column 0)
			"document.execCommand('insertParagraph')",
			"document.execCommand('insertText', false, 'Q')",
		])
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "| Name | Age |\n| --- | --- |\n| AliceQ | 30 |\n| Bob | 41 |")
		#expect(harness.coordinator.resyncCount == 0)
	}

	@Test func enterOnLastRowAppendsEmptyRow() async throws {
		let harness = try await CoordinatorBridgeHarness(source: Self.plainTable)
		try await harness.batch([
			"window.__mdPlaceCaret(47)",   // inside Bob (last row)
			"document.execCommand('insertParagraph')",
		])
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == Self.plainTable + "\n|   |   |")
		#expect(harness.coordinator.resyncCount == 0)

		// The re-render must land the caret in the new row's first cell:
		// typing with no explicit placement goes straight there.
		try await harness.waitQuiescent()
		try await harness.type("Q")
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == Self.plainTable + "\n| Q  |   |")
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func backspaceAtCellStartNeverEatsPipes() async throws {
		let harness = try await CoordinatorBridgeHarness(source: Self.table)
		try await harness.batch([
			"window.__mdPlaceCaret(31)",   // |Alice — pipe syntax to the left
			"document.execCommand('delete')",
		])
		try await Task.sleep(for: .milliseconds(300))
		// WebKit either refuses the boundary delete outright or posts a
		// cross-run delete the splicer vetoes; both must leave the source
		// intact with no resync churn.
		#expect(harness.source == Self.table)
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}
}
#endif
