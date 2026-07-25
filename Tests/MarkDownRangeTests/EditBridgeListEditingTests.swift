//
//  EditBridgeListEditingTests.swift
//  MarkDownRangeTests
//
//  Enter inside list items. The page can't splice — only the source knows
//  where the item's line starts — so it posts a continuation marker and the
//  splice has to reproduce the item's own shape: its nesting indentation and
//  its list kind. Getting the indentation wrong silently promotes a nested
//  item to the top level, which reflows the whole list.
//

#if os(macOS)
import Testing
@testable import MarkDownRange

@Suite(.serialized) @MainActor struct EditBridgeListEditingTests {
	@Test func enterAtEndOfNestedItemStaysNested() async throws {
		let source = "- alpha\n  - beta\n"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.batch([
			"window.__mdPlaceCaret(16)",   // end of "beta"
			"document.execCommand('insertParagraph')",
		])
		try await harness.waitForSourceEdits(1)
		// The new item belongs to the inner list, so it carries beta's indent.
		#expect(harness.source == "- alpha\n  - beta\n  - \n")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func typingAfterEnterInNestedItemLandsInTheNewItem() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "- alpha\n  - beta\n")
		try await harness.batch([
			"window.__mdPlaceCaret(16)",
			"document.execCommand('insertParagraph')",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		try await harness.type("g")
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == "- alpha\n  - beta\n  - g\n")
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func enterAtEndOfDeeplyNestedItemKeepsItsIndent() async throws {
		let source = "- a\n    - b\n"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.batch([
			"window.__mdPlaceCaret(11)",   // end of "b"
			"document.execCommand('insertParagraph')",
		])
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "- a\n    - b\n    - \n")
		#expect(harness.coordinator.resyncCount == 0)
	}

	@Test func enterAtEndOfOrderedItemContinuesTheNumbering() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "1. one\n2. two\n")
		try await harness.batch([
			"window.__mdPlaceCaret(13)",   // end of "two"
			"document.execCommand('insertParagraph')",
		])
		try await harness.waitForSourceEdits(1)
		// Markdown renumbers, so a literal "1." is correct for the new item.
		#expect(harness.source == "1. one\n2. two\n1. \n")
		#expect(harness.coordinator.resyncCount == 0)
	}

	@Test func enterAtEndOfNestedOrderedItemKeepsIndentAndKind() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "1. one\n   1. inner\n")
		try await harness.batch([
			"window.__mdPlaceCaret(18)",   // end of "inner"
			"document.execCommand('insertParagraph')",
		])
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "1. one\n   1. inner\n   1. \n")
		#expect(harness.coordinator.resyncCount == 0)
	}

	@Test func enterMidItemSplitsItIntoTwoItems() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "- alpha\n- beta\n")
		try await harness.batch([
			"window.__mdPlaceCaret(4)",    // al|pha
			"document.execCommand('insertParagraph')",
		])
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "- al\n- pha\n- beta\n")
		#expect(harness.coordinator.resyncCount == 0)
	}

	@Test func enterInTaskListItemKeepsTheListStructure() async throws {
		let source = "- [ ] todo\n"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.batch([
			"window.__mdPlaceCaret(10)",   // end of "todo"
			"document.execCommand('insertParagraph')",
		])
		try await harness.waitForSourceEdits(1)
		// A plain continuation item — the source stays a well-formed list either
		// way, and the user can type "[ ] " if they want another checkbox.
		#expect(harness.source.hasPrefix("- [ ] todo\n- "))
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func enterInsideBlockquoteLeavesValidSource() async throws {
		// Not (yet) quote-aware: the break isn't prefixed with "> ". What must
		// hold is that the splice is verified, lands where the caret was, and
		// never corrupts the document or churns resyncs.
		let harness = try await CoordinatorBridgeHarness(source: "> quoted\n")
		try await harness.batch([
			"window.__mdPlaceCaret(8)",
			"document.execCommand('insertParagraph')",
		])
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "> quoted\n\n\n")
		#expect(harness.coordinator.hardRejections == 0)
	}
}
#endif
