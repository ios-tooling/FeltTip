//
//  EditBridgePatchTests.swift
//  MarkDownRangeTests
//
//  Structural edits must land as in-place block patches — no navigation, no
//  full-body swap — with the caret restored and typing working immediately.
//

#if os(macOS)
import Testing
@testable import MarkDownRange

@Suite(.serialized) @MainActor struct EditBridgePatchTests {
	@Test func enterPatchesInPlaceWithoutNavigating() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha\n\nBeta\n\nGamma")
		// A nonce survives patches and body swaps but not a navigation.
		try await harness.run("window.__testNonce = 1")
		try await harness.batch([
			"window.__mdPlaceCaret(5)",
			"document.execCommand('insertParagraph')",
		])
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "Alpha\n\n\n\nBeta\n\nGamma")
		try await harness.waitQuiescent()
		let nonce = try await harness.evaluate("typeof window.__testNonce === 'number' ? 'alive' : 'gone'")
		#expect(nonce == "alive", "a structural edit must patch in place, not navigate")
		// Typing continues against the patched page.
		try await harness.type("Z", at: 7)
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == "Alpha\n\nZ\n\nBeta\n\nGamma")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func boldTogglePatchesAndKeepsSelectionWorking() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha\n\nBeta\n\nGamma")
		try await harness.run("window.__testNonce = 1")
		try await harness.batch([
			"window.__mdPlaceCaret(5)",
			"var sel = window.getSelection()",
			"for (var i = 0; i < 5; i++) sel.modify('extend', 'backward', 'character')",
			"document.execCommand('bold')",
		])
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "**Alpha**\n\nBeta\n\nGamma")
		try await harness.waitQuiescent()
		let nonce = try await harness.evaluate("typeof window.__testNonce === 'number' ? 'alive' : 'gone'")
		#expect(nonce == "alive", "a style toggle must patch in place, not navigate")
		// The tail blocks' stamps must have shifted by the four marker chars.
		try await harness.type("Y", at: 11)
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == "**Alpha**\n\nYBeta\n\nGamma")
		#expect(harness.coordinator.resyncCount == 0)
	}
}
#endif
