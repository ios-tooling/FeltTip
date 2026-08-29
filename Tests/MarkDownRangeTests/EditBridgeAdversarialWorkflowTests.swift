#if os(macOS)
	import AppKit
#else
	import UIKit
#endif
import Foundation
import Testing
@testable import MarkDownRange

@Suite("Adversarial styled editing workflows", .serialized)
@MainActor
struct EditBridgeAdversarialWorkflowTests {
	private func assertHealthy(
		_ harness: CoordinatorBridgeHarness,
		allowingResyncs resyncs: Int = 0,
		sourceLocation: SourceLocation = #_sourceLocation
	) async throws {
		try await harness.waitQuiescent()
		#expect(try await harness.stampMismatches() == [], sourceLocation: sourceLocation)
		#expect(harness.coordinator.resyncCount == resyncs, sourceLocation: sourceLocation)
		#expect(harness.coordinator.hardRejections == 0, sourceLocation: sourceLocation)
		#expect(harness.coordinator.bridgeIncidents == [], sourceLocation: sourceLocation)
	}

	private func performResponderCommand(
		_ selector: String,
		in harness: CoordinatorBridgeHarness
	) {
		harness.focusWebView()
		harness.webView.perform(NSSelectorFromString("\(selector):"), with: nil)
	}

	@Test func orphanedBeforeInputIsResyncedBeforeTheNextRealKeystroke() async throws {
		let source = "alpha beta omega"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.run("""
			window.__mdPlaceCaret(6)
			var target = window.getSelection().getRangeAt(0).cloneRange()
			var orphan = new InputEvent('beforeinput', {
			  inputType: 'insertText', data: 'ORPHAN',
			  bubbles: true, cancelable: true
			})
			Object.defineProperty(orphan, 'getTargetRanges', {
			  value: function () { return [target] }
			})
			document.body.dispatchEvent(orphan)
			window.__orphanWasDispatched = true
			""")
		try await harness.waitUntil("orphaned edit resync") {
			harness.coordinator.resyncCount == 1
		}
		#expect(harness.source == source)
		#expect(harness.sourceEditCount == 0)
		try await assertHealthy(harness, allowingResyncs: 1)

		try await harness.type("Q", at: 6)
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "alpha Qbeta omega")
		try await assertHealthy(harness, allowingResyncs: 1)
	}

	@Test func selectAllDeleteThenTypingRebuildsAnEditableDocument() async throws {
		let source = "# Heading\n\nAlpha **bold** text.\n\n> Quote\n\n- one\n- two"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.batch([
			"document.execCommand('selectAll')",
			"document.execCommand('delete')",
		])
		try await harness.waitForSourceEdits(1)
		#expect(harness.source.isEmpty)
		try await harness.waitQuiescent()

		try await harness.type("Rebuilt")
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == "Rebuilt")
		try await assertHealthy(harness)
	}

	@Test func selectAllAcrossTableCellsAndReadOnlyCodeIsSafelyRefused() async throws {
		let source = """
			Alpha

			| a | b |
			| --- | --- |
			| c | d |

			```swift
			let x = 1
			```

			Tail
			"""
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.batch([
			"document.execCommand('selectAll')",
			"document.execCommand('delete')",
			"document.execCommand('insertText', false, 'SHOULD-NOT-LAND')",
		])
		try await Task.sleep(for: .milliseconds(250))
		#expect(harness.source == source)
		#expect(harness.sourceEditCount == 0)
		#expect(try await harness.evaluate("window.__mdIsFrozen() ? 'yes' : 'no'") == "no")

		let tail = (source as NSString).range(of: "Tail").upperBound
		try await harness.type("Q", at: tail)
		try await harness.waitForSourceEdits(1)
		#expect(harness.source.hasSuffix("TailQ"))
		try await assertHealthy(harness)
	}

	@Test func canceledCompositionPublishesNothingAndDoesNotPoisonFollowingInput() async throws {
		let source = "alpha beta omega"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.batch([
			"window.__mdPlaceCaret(8)",
			"document.body.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }))",
			"document.body.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '' }))",
		])
		try await Task.sleep(for: .milliseconds(150))
		#expect(harness.source == source)
		#expect(harness.sourceEditCount == 0)

		try await harness.type("Q", at: 8)
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "alpha beQta omega")
		try await assertHealthy(harness)
	}

	@Test func compositionAcrossRunsResyncsInsteadOfGuessingThenRecovers() async throws {
		let source = "alpha **bold** omega"
		let selected = (source as NSString).range(of: "alpha **bold")
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.batch([
			"window.__mdPlaceCaret(\(selected.location), \(selected.length))",
			"document.body.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }))",
			"document.body.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: 'x' }))",
		])
		try await harness.waitUntil("cross-run composition resync") {
			harness.coordinator.resyncCount == 1
		}
		#expect(harness.source == source)
		try await assertHealthy(harness, allowingResyncs: 1)

		let omega = (source as NSString).range(of: "omega").location
		try await harness.type("Q", at: omega)
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "alpha **bold** Qomega")
		try await assertHealthy(harness, allowingResyncs: 1)
	}

	@Test func hostUpdateSupersedesMarkedTextThatFinishesAgainstTheOldPage() async throws {
		let original = "alpha beta omega"
		let newer = "HOST alpha beta omega"
		let harness = try await CoordinatorBridgeHarness(source: original)
		try await harness.batch([
			"window.__mdPlaceCaret(8)",
			"document.body.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }))",
			"document.execCommand('insertText', false, '予')",
		])
		#expect(harness.source == original, "marked text must remain DOM-only until compositionend")

		try await harness.replaceExternally(newer)
		try await harness.run("""
			document.body.dispatchEvent(new CompositionEvent('compositionend', {
			  bubbles: true, data: '予'
			}))
			""")
		try await harness.waitQuiescent()
		#expect(harness.source == newer)
		#expect(harness.sourceEditCount == 0,
			"the old composition must not publish over the host update")
		#expect(harness.coordinator.hardRejections == 0)

		let omega = (newer as NSString).range(of: "omega").location
		try await harness.type("Q", at: omega)
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "HOST alpha beta Qomega")
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func repeatedlyFlippingSelectionDirectionBeforeReplacementUsesItsFinalRange() async throws {
		let source = "zero alpha bravo charlie omega"
		let selected = (source as NSString).range(of: "alpha bravo charlie")
		let expected = (source as NSString).replacingCharacters(in: selected, with: "X")
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.run("""
			window.__mdPlaceCaret(\(selected.location), \(selected.length))
			var selection = window.getSelection()
			for (var i = 0; i < 7; i++) {
			  var r = selection.getRangeAt(0).cloneRange()
			  if (i % 2 === 0) {
			    selection.setBaseAndExtent(r.endContainer, r.endOffset, r.startContainer, r.startOffset)
			  } else {
			    selection.setBaseAndExtent(r.startContainer, r.startOffset, r.endContainer, r.endOffset)
			  }
			}
			document.execCommand('insertText', false, 'X')
			""")
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == expected)
		try await assertHealthy(harness)
	}

	@Test func appKitInsertNewlineSelectorTakesTheStructuralEnterRoute() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha\n\nBeta")
		try await harness.placeCaret(5)
		performResponderCommand("insertNewline", in: harness)
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "Alpha\n\n\n\nBeta")
		try await assertHealthy(harness)
		try await harness.type("Q")
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == "Alpha\n\nQ\n\nBeta")
	}

	@Test func appKitWordDeleteSelectorsUseTheirNativeTargetRanges() async throws {
		do {
			let source = "alpha bravo charlie"
			let bravo = (source as NSString).range(of: "bravo")
			let harness = try await CoordinatorBridgeHarness(source: source)
			try await harness.placeCaret(bravo.upperBound)
			performResponderCommand("deleteWordBackward", in: harness)
			try await harness.waitForSourceEdits(1)
			#expect(harness.source == "alpha  charlie")
			try await assertHealthy(harness)
		}
		do {
			let source = "alpha bravo charlie"
			let bravo = (source as NSString).range(of: "bravo")
			let harness = try await CoordinatorBridgeHarness(source: source)
			try await harness.placeCaret(bravo.location)
			performResponderCommand("deleteWordForward", in: harness)
			try await harness.waitForSourceEdits(1)
			#expect(harness.source == "alpha  charlie")
			try await assertHealthy(harness)
		}
	}

	@Test func wordBackspaceDeletingAWholeListRunDoesNotNeedRecovery() async throws {
		let source = "- la\n- ha\n\nTail"
		let caret = (source as NSString).range(of: "ha").upperBound
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.placeCaret(caret)
		performResponderCommand("deleteWordBackward", in: harness)
		try await harness.waitForSourceEdits(1)
		try await assertHealthy(harness)

		#expect(harness.source == "- la\n- \n\nTail")
	}

	@Test func deletingAtAListContentStartRefreshesAnActivatedHeading() async throws {
		let source = "- os\n- a# A"
		let caret = (source as NSString).range(of: "a# A").location
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.batch([
			"window.__mdPlaceCaret(\(caret))",
			"document.execCommand('forwardDelete')",
		])
		try await harness.waitForSourceEdits(1)
		try await assertHealthy(harness)

		#expect(harness.source == "- os\n- # A")
		let fresh = try await CoordinatorBridgeHarness(source: harness.source)
		#expect(
			EditBridgeFuzzTests.normalizedVisibleText(try await harness.domVisibleText())
				== EditBridgeFuzzTests.normalizedVisibleText(try await fresh.domVisibleText()))
	}

	@Test func unsupportedAppKitSoftLineDeletionCannotDesyncThePage() async throws {
		for selector in ["deleteToBeginningOfLine", "deleteToEndOfLine"] {
			let source = "alpha bravo charlie"
			let harness = try await CoordinatorBridgeHarness(source: source)
			try await harness.placeCaret(8)
			performResponderCommand(selector, in: harness)
			try await Task.sleep(for: .milliseconds(200))
			#expect(harness.source == source, "selector=\(selector)")
			#expect(harness.sourceEditCount == 0, "selector=\(selector)")
			#expect(try await harness.stampMismatches() == [], "selector=\(selector)")
			try await harness.type("Q", at: 8)
			try await harness.waitForSourceEdits(1)
			#expect(harness.source == "alpha brQavo charlie", "selector=\(selector)")
			try await assertHealthy(harness)
		}
	}
}
