//
//  EditBridgeWhitespaceBoundaryTests.swift
//  MarkDownRangeTests
//
//  Real-WebKit coverage for invisible whitespace at visual and source line
//  boundaries. The source is the oracle: an inverse key sequence must restore
//  it byte-for-byte, including spaces and tabs that HTML layout does not show.
//

#if os(macOS)
import Foundation
import Testing
@testable import MarkDownRange

@Suite(.serialized) @MainActor
struct EditBridgeWhitespaceBoundaryTests {
	private func assertHealthy(
		_ harness: CoordinatorBridgeHarness,
		sourceLocation: SourceLocation = #_sourceLocation
	) async throws {
		try await harness.waitQuiescent()
		#expect(harness.coordinator.resyncCount == 0, sourceLocation: sourceLocation)
		#expect(harness.coordinator.hardRejections == 0, sourceLocation: sourceLocation)
		#expect(harness.coordinator.bridgeIncidents == [], sourceLocation: sourceLocation)
		#expect(try await harness.stampMismatches() == [], sourceLocation: sourceLocation)
	}

	@Test func returnBackspaceRoundTripsTrailingWhitespaceMatrix() async throws {
		let cases: [(source: String, caret: Int, afterReturn: String)] = [
			("Alpha Beta\n\nTail", 6, "Alpha \n\nBeta\n\nTail"),
			("Alpha  Beta\n\nTail", 7, "Alpha  \n\nBeta\n\nTail"),
			("Alpha\tBeta\n\nTail", 6, "Alpha\t\n\nBeta\n\nTail"),
			("  Alpha Beta\n\nTail", 8, "  Alpha \n\nBeta\n\nTail"),
		]

		for item in cases {
			let harness = try await CoordinatorBridgeHarness(source: item.source)
			try await harness.run("document.querySelector('p').style.width = '60px'")
			try await harness.batch([
				"window.__mdPlaceCaret(\(item.caret))",
				"document.execCommand('insertParagraph')",
			])
			try await harness.waitForSourceEdits(1)
			#expect(harness.source == item.afterReturn,
					"source=\(String(reflecting: item.source))")
			try await harness.waitQuiescent()

			try await harness.run("document.execCommand('delete')")
			try await harness.waitForSourceEdits(2)
			#expect(harness.source == item.source,
					"source=\(String(reflecting: item.source))")
			try await assertHealthy(harness)
		}
	}

	@Test func repeatedReturnBackspaceCyclesDoNotErodeTrailingSpace() async throws {
		let source = "Alpha Beta\n\nTail"
		let harness = try await CoordinatorBridgeHarness(source: source)
		for cycle in 1...3 {
			try await harness.batch([
				"window.__mdPlaceCaret(6)",
				"document.execCommand('insertParagraph')",
			])
			try await harness.waitForSourceEdits(cycle * 2 - 1)
			#expect(harness.source == "Alpha \n\nBeta\n\nTail")
			try await harness.waitQuiescent()

			try await harness.run("document.execCommand('delete')")
			try await harness.waitForSourceEdits(cycle * 2)
			#expect(harness.source == source, "cycle=\(cycle)")
			try await assertHealthy(harness)
		}
	}

	@Test func typingAfterReturnBackspaceLandsAfterThePreservedSpace() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha Beta\n\nTail")
		try await harness.batch([
			"window.__mdPlaceCaret(6)",
			"document.execCommand('insertParagraph')",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		try await harness.run("document.execCommand('delete')")
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()

		try await harness.type("X")
		try await harness.waitForSourceEdits(3)
		#expect(harness.source == "Alpha XBeta\n\nTail")
		try await assertHealthy(harness)
	}

	@Test func backspaceMergePreservesWhitespaceOnBothSidesOfSeparator() async throws {
		let source = "Alpha \n\n  Beta\n\nTail"
		let beta = (source as NSString).range(of: "Beta").location
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.batch([
			"window.__mdPlaceCaret(\(beta))",
			"document.execCommand('delete')",
		])
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "Alpha   Beta\n\nTail")
		try await assertHealthy(harness)
	}

	@Test func forwardDeleteMergePreservesNextLinesLeadingWhitespace() async throws {
		let source = "Alpha\n\n  Beta\n\nTail"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.batch([
			"window.__mdPlaceCaret(5)",
			"document.execCommand('forwardDelete')",
		])
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "Alpha  Beta\n\nTail")
		try await assertHealthy(harness)
	}

	@Test func insertionAtVisibleLineStartPreservesHiddenLeadingWhitespace() async throws {
		let source = "Alpha\n\n  Beta\n\nTail"
		let beta = (source as NSString).range(of: "Beta").location
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.type("X", at: beta)
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "Alpha\n\n  XBeta\n\nTail")
		try await assertHealthy(harness)
	}
}
#endif
