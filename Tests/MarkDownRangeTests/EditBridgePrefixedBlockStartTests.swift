//
//  EditBridgePrefixedBlockStartTests.swift
//  MarkDownRangeTests
//

#if os(macOS)
import Foundation
import Testing
@testable import MarkDownRange

@Suite(.serialized) @MainActor
struct EditBridgePrefixedBlockStartTests {
	@Test func enterBeforeHeadingMovesItsMarkerAndRestoresTheBlankCaret() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "# Heading\n\nTail")
		try await harness.batch([
			"window.__mdPlaceCaret(2)",
			"document.execCommand('insertParagraph')",
		])
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "\n\n# Heading\n\nTail")

		try await harness.waitQuiescent()
		try await harness.type("Before")
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == "Before\n\n# Heading\n\nTail")
		try await assertHealthy(harness)
	}

	@Test func enterAtOtherVisualBlockStartsKeepsTheirWholeSourceTogether() async throws {
		let cases: [(source: String, caret: Int)] = [
			("Plain paragraph\n\nTail", 0),
			("**Bold opening**\n\nTail", 2),
			("Setext heading\n==============\n\nTail", 0),
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
			try await harness.type("Before")
			try await harness.waitForSourceEdits(2)
			#expect(harness.source == "Before\n\n" + item.source)
			try await assertHealthy(harness)
		}
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

	private func assertHealthy(_ harness: CoordinatorBridgeHarness) async throws {
		try await harness.waitQuiescent()
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
		#expect(try await harness.stampMismatches().isEmpty)
	}
}
#endif
