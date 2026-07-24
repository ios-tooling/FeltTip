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

	@Test func enterInCellIsSwallowed() async throws {
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
