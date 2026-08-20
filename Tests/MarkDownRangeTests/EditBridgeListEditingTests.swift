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

import Foundation
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
		#expect(harness.source == "- [ ] todo\n- [ ] \n")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
		try await harness.waitQuiescent()
		#expect(try await harness.stampMismatches().isEmpty)
	}

	@Test func typingAfterAddingATaskLandsAfterTheNewCheckbox() async throws {
		let harness = try await CoordinatorBridgeHarness(
			source: "- [x] finished\n")
		try await harness.batch([
			"window.__mdPlaceCaret(14)",
			"document.execCommand('insertParagraph')",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		try await harness.type("next")
		try await harness.waitForSourceEdits(2)

		#expect(harness.source == "- [x] finished\n- [ ] next\n")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
		#expect(try await harness.stampMismatches().isEmpty)
	}

	@Test func menuRouteAddsAStyledListItem() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "- first\n")
		try await harness.batch([
			"window.__mdPlaceCaret(7)",
			"window.__mdInsertListItem()",
		])
		try await harness.waitForSourceEdits(1)

		#expect(harness.source == "- first\n- \n")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func menuRouteOutsideAListIsANoopAndLeavesEditingUsable() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "paragraph\n")
		try await harness.batch([
			"window.__mdPlaceCaret(4)",
			"window.__mdInsertListItem()",
		])
		try await Task.sleep(for: .milliseconds(100))
		#expect(harness.source == "paragraph\n")
		#expect(harness.sourceEditCount == 0)

		try await harness.type("X")
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "paraXgraph\n")
		#expect(harness.coordinator.resyncCount == 0)
	}

	@Test func everyEditableListGetsABottomRightAddButton() async throws {
		let source = "- outer\n  - nested\n\nparagraph\n\n1. ordered\n"
		let harness = try await CoordinatorBridgeHarness(source: source)
		let inspection = try await harness.evaluate("""
			JSON.stringify(Array.from(
			  document.querySelectorAll('.md-list-add-button')
			).map(function (button) {
			  var list = button.parentElement;
			  var b = button.getBoundingClientRect();
			  var l = list.getBoundingClientRect();
			  return {
			    editable: button.contentEditable,
			    text: button.textContent,
			    rightInset: Math.round(l.right - b.right),
			    bottomInset: Math.round(l.bottom - b.bottom)
			  };
			}))
			""")
		let data = try #require(inspection?.data(using: .utf8))
		let buttons = try JSONDecoder().decode(
			[ListButtonInspection].self, from: data)

		#expect(buttons.count == 3)
		#expect(buttons.allSatisfy { $0.editable == "false" })
		#expect(buttons.allSatisfy { $0.text.isEmpty })
		#expect(buttons.allSatisfy { (0...4).contains($0.rightInset) })
		#expect(buttons.allSatisfy { (0...4).contains($0.bottomInset) })
	}

	@Test func clickingAListsButtonAppendsAndFocusesItsNewTask() async throws {
		let source = "- first\n\nparagraph\n\n- [x] finished\n"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.run("""
			document.querySelectorAll(
			  '.md-list-add-button'
			)[1].click()
			""")
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		try await harness.type("next")
		try await harness.waitForSourceEdits(2)

		#expect(harness.source
			== "- first\n\nparagraph\n\n- [x] finished\n- [ ] next\n")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
		#expect(try await harness.stampMismatches().isEmpty)
	}

	@Test func commandReturnPrefersTheListContainingTheCaret() async throws {
		let source = "- first\n\nparagraph\n\n1. second\n"
		let harness = try await CoordinatorBridgeHarness(source: source)
		let secondEnd = NSMaxRange((source as NSString).range(of: "second"))
		try await harness.batch([
			"window.__mdPlaceCaret(\(secondEnd))",
			"""
			document.dispatchEvent(new KeyboardEvent('keydown', {
			  key: 'Enter', metaKey: true, bubbles: true, cancelable: true
			}))
			""",
		])
		try await harness.waitForSourceEdits(1)

		#expect(harness.source
			== "- first\n\nparagraph\n\n1. second\n1. \n")
		#expect(harness.coordinator.resyncCount == 0)
	}

	@Test func commandReturnWithoutASelectionUsesTheFirstVisibleList() async throws {
		let source = "- first\n\nparagraph\n\n1. second\n"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.run("""
			window.getSelection().removeAllRanges();
			document.dispatchEvent(new KeyboardEvent('keydown', {
			  key: 'Enter', metaKey: true, bubbles: true, cancelable: true
			}));
			""")
		try await harness.waitForSourceEdits(1)

		#expect(harness.source
			== "- first\n- \n\nparagraph\n\n1. second\n")
		#expect(harness.coordinator.resyncCount == 0)
	}

	@Test func commandReturnSkipsListsAboveTheViewport() async throws {
		let spacer = (0..<80)
			.map { "Paragraph \($0) filling vertical space." }
			.joined(separator: "\n\n")
		let source = "- above\n\n\(spacer)\n\n- visible\n"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.run("""
			var lists = document.querySelectorAll('ul, ol');
			lists[1].scrollIntoView({ block: 'start' });
			window.getSelection().removeAllRanges();
			document.dispatchEvent(new KeyboardEvent('keydown', {
			  key: 'Enter', metaKey: true, bubbles: true, cancelable: true
			}));
			""")
		try await harness.waitForSourceEdits(1)

		#expect(harness.source == source.dropLast() + "\n- \n")
		#expect(harness.coordinator.resyncCount == 0)
	}

	@Test func listButtonsAreReinstalledOnceAfterAnIncrementalPatch() async throws {
		let harness = try await CoordinatorBridgeHarness(
			source: "- first\n\nparagraph\n\n- second\n")
		try await harness.run(
			"document.querySelector('.md-list-add-button').click()")
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		let count = try await harness.evaluate(
			"String(document.querySelectorAll('.md-list-add-button').length)")
		#expect(count == "2")
		#expect(harness.coordinator.resyncCount == 0)
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

	private struct ListButtonInspection: Decodable {
		let editable: String
		let text: String
		let rightInset: Int
		let bottomInset: Int
	}
}
