//
//  EditBridgeWhitespaceBoundaryTests.swift
//  MarkDownRangeTests
//
//  Real-WebKit coverage for invisible whitespace at visual and source line
//  boundaries. The source is the oracle: an inverse key sequence must restore
//  it byte-for-byte, including spaces and tabs that HTML layout does not show.
//

import Foundation
import Testing
@testable import MarkDownRange

#if os(macOS)
	import AppKit
#endif

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

	@Test func forwardDeleteOfOneRepeatedSpaceDoesNotNeedRecovery() async throws {
		let source = "text de ewor samle  beta"
		let caret = (source as NSString).range(of: "samle").upperBound
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.batch([
			"window.__mdPlaceCaret(\(caret))",
			"document.execCommand('forwardDelete')",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		#expect(harness.source == "text de ewor samle beta")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func insertingAnotherRepeatedSpaceDoesNotNeedRecovery() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "b  pl")
		try await harness.type(" ", at: 3)
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		#expect(harness.source == "b   pl")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func backspaceExposingRepeatedSpacesDoesNotNeedRecovery() async throws {
		let source = "gamm  gamma"
		let caret = (source as NSString).range(of: "gamma").location + 1
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.batch([
			"window.__mdPlaceCaret(\(caret))",
			"document.execCommand('delete')",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		#expect(harness.source == "gamm  amma")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func typingTextAfterRepeatedSpacesDoesNotNeedRecovery() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "ma  tet")
		try await harness.type("é", at: 4)
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		#expect(harness.source == "ma  étet")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func typingTextBetweenRepeatedSpacesDoesNotNeedRecovery() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "h de  bea")
		try await harness.type("é", at: 5)
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		#expect(harness.source == "h de é bea")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func insertingThenDeletingARepeatedSpaceRestoresTheRenderedBaseline() async throws {
		let source = "eta ds **gmma**"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.type(" ", at: 3)
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "eta  ds **gmma**")

		try await harness.batch([
			"window.__mdPlaceCaret(4)",
			"document.execCommand('delete')",
		])
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()

		#expect(harness.source == source)
		#expect(harness.coordinator.resyncCount == 0)
		#expect(try await harness.stampMismatches() == [])
		let fresh = try await CoordinatorBridgeHarness(source: source)
		#expect(
			EditBridgeFuzzTests.normalizedVisibleText(try await harness.domVisibleText())
				== EditBridgeFuzzTests.normalizedVisibleText(try await fresh.domVisibleText()))
	}

	@Test func forwardDeleteDuringAWhitespaceRenderFreezeIsReplayed() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "eta ds")
		try await harness.batch([
			"window.__mdPlaceCaret(4)",
			"document.execCommand('insertText', false, ' ')",
			"document.execCommand('forwardDelete')",
		])
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()

		#expect(harness.source == "eta  s")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func mixedTypingAndDeletionQueuedAcrossSuccessiveFreezesKeepTheirOrder() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "eta ds")
		try await harness.batch([
			"window.__mdPlaceCaret(4)",
			"document.execCommand('insertText', false, ' ')",
			"document.execCommand('insertText', false, 'X')",
			"document.execCommand('delete')",
		])
		try await harness.waitForSourceEdits(3)
		try await harness.waitQuiescent()

		#expect(harness.source == "eta  ds")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(try await harness.stampMismatches() == [])
	}

	#if os(macOS)
		@Test func wordBackspaceExposingTrailingSpacesDoesNotNeedRecovery() async throws {
			let source = "ex de  bea\n\nTail"
			let caret = (source as NSString).range(of: "bea").upperBound
			let harness = try await CoordinatorBridgeHarness(source: source)
			try await harness.placeCaret(caret)
			harness.focusWebView()
			harness.webView.perform(
				NSSelectorFromString("deleteWordBackward:"), with: nil)
			try await harness.waitForSourceEdits(1)
			try await harness.waitQuiescent()

			#expect(harness.source == "ex de  \n\nTail")
			#expect(harness.coordinator.resyncCount == 0)
			#expect(try await harness.stampMismatches() == [])
		}
	#endif

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
