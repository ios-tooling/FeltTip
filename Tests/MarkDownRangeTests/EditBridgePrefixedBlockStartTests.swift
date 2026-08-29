//
//  EditBridgePrefixedBlockStartTests.swift
//  MarkDownRangeTests
//

import Foundation
import Testing
@testable import MarkDownRange

@Suite(.serialized) @MainActor
struct EditBridgePrefixedBlockStartTests {
	@Test func enterBeforeHeadingMovesItsMarkerAndKeepsCaretWithHeading() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "# Heading\n\nTail")
		try await harness.batch([
			"window.__mdPlaceCaret(2)",
			"document.execCommand('insertParagraph')",
		])
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "\n\n# Heading\n\nTail")

		try await harness.waitQuiescent()
		#expect(try await harness.evaluate("document.querySelectorAll('[data-md-visual-blank]').length === 1 ? 'yes' : 'no'") == "yes")
		try await harness.type("Before")
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == "\n\n# BeforeHeading\n\nTail")
		try await assertHealthy(harness)
	}

	@Test func enterAtOtherVisualBlockStartsKeepsTheirWholeSourceTogether() async throws {
		let cases: [(source: String, caret: Int, afterTyping: String)] = [
			("Plain paragraph\n\nTail", 0, "\n\nBeforePlain paragraph\n\nTail"),
			("**Bold opening**\n\nTail", 2, "\n\n**BeforeBold opening**\n\nTail"),
			("Setext heading\n==============\n\nTail", 0, "\n\nBeforeSetext heading\n==============\n\nTail"),
		]
		for item in cases {
			let harness = try await CoordinatorBridgeHarness(source: item.source)
			try await harness.batch([
				"window.__mdPlaceCaret(\(item.caret))",
				"document.execCommand('insertParagraph')",
			])
			try await harness.waitForSourceEdits(1)
			#expect(harness.source == "\n\n" + item.source)

			try await harness.waitQuiescent()
			#expect(try await harness.evaluate("document.querySelectorAll('[data-md-visual-blank]').length === 1 ? 'yes' : 'no'") == "yes")
			try await harness.type("Before")
			try await harness.waitForSourceEdits(2)
			#expect(harness.source == item.afterTyping)
			try await assertHealthy(harness)
		}
	}

	@Test func enterBeforeBoldParagraphAfterPlainParagraphMovesCaretWithLine() async throws {
		let source = "Print the stored authentication token\n\n**Examples:**\n\nCommand"
		let harness = try await CoordinatorBridgeHarness(source: source)
		let caret = (source as NSString).range(of: "Examples:").location
		try await harness.batch([
			"window.__mdPlaceCaret(\(caret))",
			"document.execCommand('insertParagraph')",
		])
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "Print the stored authentication token\n\n\n\n**Examples:**\n\nCommand")
		try await harness.waitQuiescent()

		let caretState = try await harness.evaluate("""
			(function () {
			  var selection = window.getSelection()
			  if (!selection || !selection.rangeCount) return 'missing'
			  var node = selection.getRangeAt(0).startContainer
			  var element = node.nodeType === 1 ? node : node.parentElement
			  var block = element && element.closest('p, li, h1, h2, h3, h4, h5, h6')
			  var previous = block && block.previousElementSibling
			  var spacer = previous && previous.hasAttribute('data-md-visual-blank') ? 'spacer' : 'no-spacer'
			  return block ? block.textContent + '|' + spacer : 'missing'
			})()
			""")
		#expect(caretState == "Examples:|spacer", "caret/blank row state was \(caretState ?? "missing")")
		try await harness.type("Before")
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == "Print the stored authentication token\n\n\n\n**BeforeExamples:**\n\nCommand")
		try await assertHealthy(harness)
	}

	@Test func enterMovesNestedQuoteHeadingAndHiddenInlinePrefixTogether() async throws {
		let source = "> ## **Heading**\n\nTail"
		let heading = (source as NSString).range(of: "Heading")
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.batch([
			"window.__mdPlaceCaret(\(heading.location))",
			"document.execCommand('insertParagraph')",
		])
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "\n\n> ## **Heading**\n\nTail")
		try await assertHealthy(harness)
	}

	@Test func enterBeforeQuotedParagraphMovesTheQuoteMarker() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "> Quoted\n\nTail")
		try await harness.batch([
			"window.__mdPlaceCaret(2)",
			"document.execCommand('insertParagraph')",
		])
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "\n\n> Quoted\n\nTail")
		try await assertHealthy(harness)
	}

	@Test func enterBeforeListTextKeepsListContinuationSemantics() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "- Item\n- Tail")
		try await harness.batch([
			"window.__mdPlaceCaret(2)",
			"document.execCommand('insertParagraph')",
		])
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "- \n- Item\n- Tail")
		try await assertHealthy(harness)
	}

	@Test func typingIntoHiddenLeadingWhitespaceRefreshesItsParagraph() async throws {
		let source = "Before\n\n   ** zwo**\n\nAfter"
		let caret = (source as NSString).range(of: "   ** zwo**").location
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.batch([
			"window.__mdPlaceCaret(\(caret))",
			"document.execCommand('insertText', false, 'a')",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		#expect(harness.source == "Before\n\na   ** zwo**\n\nAfter")

		let fresh = try await CoordinatorBridgeHarness(source: harness.source)
		let liveText = EditBridgeFuzzTests.normalizedVisibleText(try await harness.domVisibleText())
		let freshText = EditBridgeFuzzTests.normalizedVisibleText(try await fresh.domVisibleText())
		#expect(liveText == freshText)
		try await assertHealthy(harness)
	}

	private func assertHealthy(_ harness: CoordinatorBridgeHarness) async throws {
		try await harness.waitQuiescent()
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
		#expect(try await harness.stampMismatches().isEmpty)
	}
}
