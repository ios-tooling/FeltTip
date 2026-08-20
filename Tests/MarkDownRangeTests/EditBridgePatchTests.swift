//
//  EditBridgePatchTests.swift
//  MarkDownRangeTests
//
//  Structural edits must land as in-place block patches — no navigation, no
//  full-body swap — with the caret restored and typing working immediately.
//

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

	@Test func oneCharacterHostEditPatchesOneBlockInALargeDocumentWithoutBlockingOrMoving() async throws {
		let paragraphs = (0..<800).map { "Paragraph \($0) with enough text to make this a realistically tall styled document." }
		let source = paragraphs.joined(separator: "\n\n")
		let harness = try await CoordinatorBridgeHarness(source: source)

		let target = try #require(source.range(of: "Paragraph 400"))
		let editOffset = source.utf16.distance(from: source.utf16.startIndex, to: target.upperBound)
		let edited = (source as NSString).replacingCharacters(
			in: NSRange(location: editOffset, length: 0), with: "X")

		// Tag unchanged blocks on either side. A whole-body swap preserves the
		// page nonce but replaces these elements; a one-block patch preserves
		// both identities and replaces only the edited paragraph.
		try await harness.run("""
			window.__testNonce = 1;
			var blocks = Array.from(document.body.children).filter(e => e.querySelector && e.querySelector('[data-s]'));
			blocks[20].dataset.testIdentity = 'before';
			blocks[780].dataset.testIdentity = 'after';
			window.scrollTo(0, blocks[400].offsetTop);
			window.__testScrollY = window.scrollY;
			""")
		let heartbeat = Task { @MainActor () -> Int in
			var ticks = 0
			while !Task.isCancelled {
				try? await Task.sleep(for: .milliseconds(1))
				ticks += 1
			}
			return ticks
		}
		try await harness.replaceExternally(edited)
		try await harness.waitUntil("large host edit committed") {
			harness.coordinator.currentSource == edited
		}
		try await harness.waitQuiescent()
		heartbeat.cancel()
		let ticks = await heartbeat.value

		#expect(harness.source == edited)
		#expect(harness.coordinator.currentSource == edited)
		#expect(ticks >= 3, "main actor only ticked \(ticks)× while the large edit rendered")
		#expect(try await harness.evaluate("window.__testNonce === 1 ? 'alive' : 'gone'") == "alive")
		#expect(try await harness.evaluate(
			"document.querySelector('[data-test-identity=\"before\"]') && document.querySelector('[data-test-identity=\"after\"]') ? 'yes' : 'no'"
		) == "yes", "unchanged blocks were replaced instead of patching only the edited block")
		let scrollDelta = try await harness.evaluate(
			"String(Math.abs(window.scrollY - window.__testScrollY))").flatMap(Double.init) ?? .infinity
		#expect(scrollDelta < 60, "scroll moved \(scrollDelta)px during a one-block patch")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func rapidHostUpdatesApplyOnlyTheNewestRender() async throws {
		let base = (0..<600).map { "Paragraph \($0) base text." }.joined(separator: "\n\n")
		let harness = try await CoordinatorBridgeHarness(source: base)
		try await harness.run("window.__testNonce = 1")

		let first = base.replacingOccurrences(of: "Paragraph 100", with: "FIRST 100")
		let second = base.replacingOccurrences(of: "Paragraph 300", with: "SECOND 300")
		let final = base.replacingOccurrences(of: "Paragraph 500", with: "FINAL 500")
		try await harness.replaceExternally(first)
		try await harness.replaceExternally(second)
		try await harness.replaceExternally(final)
		try await harness.waitUntil("newest host update committed") {
			harness.coordinator.currentSource == final
		}
		try await harness.waitQuiescent()

		#expect(harness.source == final)
		#expect(harness.coordinator.currentSource == final)
		#expect(try await harness.evaluate("document.body.textContent.includes('FINAL 500') ? 'yes' : 'no'") == "yes")
		#expect(try await harness.evaluate(
			"document.body.textContent.includes('FIRST 100') || document.body.textContent.includes('SECOND 300') ? 'stale' : 'clean'"
		) == "clean")
		#expect(try await harness.evaluate("window.__testNonce === 1 ? 'alive' : 'gone'") == "alive")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func typingAgainstAStalePageCannotOverwriteNewerHostText() async throws {
		let source = "Alpha paragraph\n\nBeta paragraph"
		let harness = try await CoordinatorBridgeHarness(source: source)
		let hostText = "RAW-" + source

		try await harness.replaceExternally(hostText)
		// This command targets the still-visible old DOM while the host update
		// is inside its debounce/render window. It must be blocked or dropped,
		// never published as an old-source replacement.
		try await harness.type("STALE-", at: 0)
		try await harness.waitUntil("host text committed") {
			harness.coordinator.currentSource == hostText
		}
		try await harness.waitQuiescent()

		#expect(harness.source == hostText)
		#expect(harness.sourceEditCount == 0)
		#expect(try await harness.stampMismatches() == [])

		// The freeze ends with the patch and normal styled editing resumes.
		try await harness.type("Q", at: 0)
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "Q" + hostText)
	}

	@Test func aNewHostUpdateSupersedesAnInFlightStructuralPatch() async throws {
		let source = (0..<500).map { "Paragraph \($0) body." }.joined(separator: "\n\n")
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.run("window.__testNonce = 1")

		try await harness.batch([
			"window.__mdPlaceCaret(11)",
			"document.execCommand('insertParagraph')",
		])
		try await harness.waitForSourceEdits(1)
		let final = source.replacingOccurrences(of: "Paragraph 250", with: "HOST-WINS 250")
		try await harness.replaceExternally(final)
		try await harness.waitUntil("superseding host update committed") {
			harness.coordinator.currentSource == final
		}
		try await harness.waitQuiescent()

		#expect(harness.source == final)
		#expect(harness.coordinator.currentSource == final)
		#expect(try await harness.evaluate("document.body.textContent.includes('HOST-WINS 250') ? 'yes' : 'no'") == "yes")
		#expect(try await harness.evaluate("window.__testNonce === 1 ? 'alive' : 'gone'") == "alive")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
		#expect(try await harness.stampMismatches() == [])

		// The winning page must be live, not merely visually correct.
		let edits = harness.sourceEditCount
		try await harness.type("Q", at: 0)
		try await harness.waitForSourceEdits(edits + 1)
		#expect(harness.source.hasPrefix("QParagraph 0"))
	}
}
