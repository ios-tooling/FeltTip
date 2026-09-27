//
//  EditBridgeBatchingTests.swift
//  FeltTipTests
//
//  The hazard behind "type it twice": WebKit batches several editing commands
//  into one turn, and every edit after the first captured its offsets against
//  stamps that hadn't shifted yet. With eager queue-time shifts and the
//  revision gate, whole batches must apply cleanly — zero resyncs.
//

import Testing
@testable import FeltTip

@Suite(.serialized) @MainActor struct EditBridgeBatchingTests {
	@Test func twoInsertsInOneTurnBothLand() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha\n\nBeta")
		try await harness.batch([
			"window.__mdPlaceCaret(5)",
			"document.execCommand('insertText', false, 'X')",
			"document.execCommand('insertText', false, 'Y')",
		])
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == "AlphaXY\n\nBeta")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func insertThenDeleteInOneTurn() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha\n\nBeta")
		try await harness.batch([
			"window.__mdPlaceCaret(5)",
			"document.execCommand('insertText', false, 'X')",
			"document.execCommand('delete')",
		])
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == "Alpha\n\nBeta")
		#expect(harness.coordinator.resyncCount == 0)
	}

	@Test func retrocurlShapedBatchAcrossOneRun() async throws {
		// Simulates smart-quote retrocurl: the second command REPLACES text
		// earlier in the same run than the first insertion.
		let harness = try await CoordinatorBridgeHarness(source: "say \"hi\" now\n\nBeta")
		try await harness.batch([
			"window.__mdPlaceCaret(8)",
			"document.execCommand('insertText', false, 'X')",
			"var sel = window.getSelection()",
			"for (var i = 0; i < 4; i++) sel.modify('move', 'backward', 'character')",
			"sel.modify('extend', 'backward', 'character')",
			"document.execCommand('insertText', false, '\\u201C')",
		])
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == "say \u{201C}hi\"X now\n\nBeta")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func batchTouchingTwoParagraphsShiftsLaterStamps() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha\n\nBeta\n\nGamma")
		try await harness.batch([
			"window.__mdPlaceCaret(5)",
			"document.execCommand('insertText', false, 'XX')",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.type("Y", at: 9)   // start of Beta, post-shift
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == "AlphaXX\n\nYBeta\n\nGamma")
		#expect(harness.coordinator.resyncCount == 0)
	}

	@Test func rapidSequentialTypingNeverResyncs() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha\n\nBeta")
		try await harness.placeCaret(5)
		for ch in ["a", "b", "c", "d", "e", " ", "f"] {
			try await harness.type(ch)
		}
		try await harness.waitForSourceEdits(7)
		#expect(harness.source == "Alphaabcde f\n\nBeta")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}
}
