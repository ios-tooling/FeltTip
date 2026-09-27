//
//  EditBridgeFreezeAndResyncTests.swift
//  FeltTipTests
//
//  The freeze lifecycle (structural edits swallow input until the re-render)
//  and the resync paths (revision mismatch, stale-epoch stragglers, and the
//  frozenTimeout safety net for a re-render that never arrives).
//

import Testing
@testable import FeltTip

@Suite(.serialized) @MainActor struct EditBridgeFreezeAndResyncTests {
	@Test func enterSplitsParagraphAndTypingResumesAfterReload() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha\n\nBeta")
		try await harness.batch([
			"window.__mdPlaceCaret(5)",
			"document.execCommand('insertParagraph')",
		])
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "Alpha\n\n\n\nBeta")
		try await harness.waitQuiescent()
		// The round-trip reload reinjected the script and reseeded the rev;
		// typing must work immediately.
		try await harness.type("Z", at: 7)
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == "Alpha\n\nZ\n\nBeta")
		#expect(harness.coordinator.resyncCount == 0)
	}

	@Test func typingWhileFrozenIsBufferedWithoutPrematureSourceEdits() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha\n\nBeta")
		harness.suppressRoundTrip = true
		try await harness.batch([
			"window.__mdPlaceCaret(5)",
			"document.execCommand('insertParagraph')",
			// Still in the same turn — the page is frozen now. These are buffered,
			// not mapped against a source that changed shape; with the round trip
			// deliberately suppressed there is not yet a restored caret to replay.
			"document.execCommand('insertText', false, 'X')",
			"document.execCommand('insertText', false, 'Y')",
		])
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "Alpha\n\n\n\nBeta")
		#expect(harness.sourceEditCount == 1, "frozen text must not edit before caret restoration")
	}

	@Test func vetoedStructuralEditDiscardsBufferedTyping() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha\n\nBeta")
		harness.suppressRoundTrip = true
		try await harness.batch([
			"window.__mdPlaceCaret(5)",
			"document.execCommand('insertParagraph')",
			"document.execCommand('insertText', false, 'X')",
			"window.__mdUnfreeze(0)",
			"window.__mdPlaceCaret(0)",
		])
		try await harness.waitForSourceEdits(1)
		try await Task.sleep(for: .milliseconds(100))
		#expect(harness.source == "Alpha\n\n\n\nBeta")
		#expect(harness.sourceEditCount == 1, "vetoed buffer leaked into a later caret")
	}

	@Test func frozenTimeoutResyncsWhenTheReRenderNeverComes() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha\n\nBeta")
		harness.suppressRoundTrip = true   // simulate the lost re-render
		try await harness.batch([
			"window.__mdPlaceCaret(5)",
			"document.execCommand('insertParagraph')",
		])
		try await harness.waitForSourceEdits(1)
		// The 2s deadline posts frozenTimeout; the coordinator resyncs from
		// its own currentSource, which unfreezes the page.
		try await harness.waitUntil("frozenTimeout resync") { harness.coordinator.resyncCount >= 1 }
		try await harness.waitQuiescent()
		try await harness.type("Z", at: 7)
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == "Alpha\n\nZ\n\nBeta", "typing must come back after the safety-net resync")
	}

	@Test func staleEpochMessageIsDroppedNotSpliced() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha\n\nBeta")
		// Post a message whose rev predates the page's seeded epoch — the
		// shape of an in-flight edit racing a reload. It must be dropped.
		try await harness.run("""
			window.webkit.messageHandlers.mdedit.postMessage({
				start: 0, end: 0, text: 'X', expected: '', before: '', after: '', rev: 0, seq: 999 })
			""")
		try await harness.waitUntil("stale drop") { harness.coordinator.droppedStaleEdits >= 1 }
		#expect(harness.source == "Alpha\n\nBeta")
		#expect(harness.coordinator.resyncCount == 0, "a stale straggler must not trigger a resync")
	}

	@Test func futureRevMismatchResyncsDeterministically() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha\n\nBeta")
		let rev = harness.coordinator.currentRev
		try await harness.run("""
			window.webkit.messageHandlers.mdedit.postMessage({
				start: 0, end: 0, text: 'X', expected: '', before: '', after: '', rev: \(rev + 5), seq: 999 })
			""")
		try await harness.waitUntil("mismatch resync") { harness.coordinator.resyncCount >= 1 }
		#expect(harness.source == "Alpha\n\nBeta", "a mismatched edit must never splice")
		try await harness.waitQuiescent()
		try await harness.type("Z", at: 0)
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "ZAlpha\n\nBeta", "typing must work after the resync")
	}

	@Test func revisionlessEditCannotMutateSourceAndEditingRecovers() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha\n\nBeta")
		try await harness.run("""
			window.webkit.messageHandlers.mdedit.postMessage({
				start: 0, end: 0, text: 'X', expected: '',
				before: '', after: '', seq: 999
			})
			""")
		try await harness.waitUntil("revisionless edit resync") {
			harness.coordinator.resyncCount >= 1
		}
		#expect(harness.source == "Alpha\n\nBeta")
		#expect(harness.sourceEditCount == 0)

		try await harness.waitQuiescent()
		try await harness.type("Z", at: 0)
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "ZAlpha\n\nBeta")
	}
}
