//
//  EditBridgeWhitespaceBoundaryTests.swift
//  FeltTipTests
//
//  Real-WebKit coverage for invisible whitespace at visual and source line
//  boundaries. The source is the oracle: an inverse key sequence must restore
//  it byte-for-byte, including spaces and tabs that HTML layout does not show.
//

import Foundation
import Testing
@testable import FeltTip

#if os(macOS)
	import AppKit
#endif

@Suite(.serialized) @MainActor
struct EditBridgeWhitespaceBoundaryTests {
	@Test func repeatedSpacesRemainVisibleAndBackspaceRemovesOne() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha Beta")
		try await harness.type(" ", at: 6)
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		try await harness.type(" ")
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()
		#expect(harness.source == "Alpha   Beta")
		#expect(try await harness.evaluate("document.querySelector('p').innerText") == "Alpha   Beta")
		let widths = try await harness.evaluate("""
		  var node = document.querySelector('p [data-s]').firstChild;
		  JSON.stringify([5, 6, 7].map(i => {
		    var r = document.createRange(); r.setStart(node, i); r.setEnd(node, i + 1);
		    return r.getBoundingClientRect().width > 0;
		  }))
		  """)
		#expect(widths == "[true,true,true]")
		try await harness.run("document.execCommand('delete')")
		try await harness.waitForSourceEdits(3)
		#expect(harness.source == "Alpha  Beta")
		try await assertHealthy(harness)
	}

	@Test func tabInsertsLiteralWhitespaceAndKeepsTypingAtTheCaret() async throws {
		for source in ["Alpha Beta", "Alpha", "# Alpha", "- Alpha Beta", "- Alpha", "```\nAlpha Beta\n```"] {
			let harness = try await CoordinatorBridgeHarness(source: source)
			let caret = (source as NSString).range(of: "Alpha").upperBound
			try await harness.placeCaret(caret)
			try await harness.run("""
			  document.body.dispatchEvent(new KeyboardEvent('keydown', {
			    key: 'Tab', bubbles: true, cancelable: true
			  }))
			  """)
			try await harness.waitForSourceEdits(1)
			try await harness.waitQuiescent()
			#expect(harness.source == source.replacingOccurrences(of: "Alpha", with: "Alpha\t"))
			try await harness.type("X")
			try await harness.waitForSourceEdits(2)
			#expect(harness.source == source.replacingOccurrences(of: "Alpha", with: "Alpha\tX"))
			try await assertHealthy(harness)
		}
	}

	@Test func rapidTabsAndTypingReplayInOrder() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "AlphaBeta")
		try await harness.placeCaret(5)
		try await harness.run("""
		  function tab() {
		    document.body.dispatchEvent(new KeyboardEvent('keydown', {
		      key: 'Tab', bubbles: true, cancelable: true
		    }));
		  }
		  tab(); tab(); document.execCommand('insertText', false, 'X');
		  """)
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()
		#expect(harness.source == "Alpha\t\tXBeta")
		try await assertHealthy(harness)
	}

	@Test func trailingSpacesStayVisibleWhileTypingAndDeleting() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha")
		try await harness.type(" ", at: 5)
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		try await harness.type(" ")
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()
		#expect(harness.source == "Alpha  ")
		#expect(try await harness.evaluate("document.querySelector('p').innerText") == "Alpha  ")
		try await harness.run("document.execCommand('delete')")
		try await harness.waitForSourceEdits(3)
		#expect(harness.source == "Alpha ")
		try await harness.type("X")
		try await harness.waitForSourceEdits(4)
		#expect(harness.source == "Alpha X")
		try await assertHealthy(harness)
	}

	@Test func physicalSpacesRejectPeriodSubstitutionButAnExplicitPeriodStillTypes() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "AlphaBeta")
		try await harness.placeCaret(5)
		try await harness.run("""
		  document.body.dispatchEvent(new KeyboardEvent('keydown', {
		    key: ' ', bubbles: true, cancelable: true
		  }));
		  """)
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		try await harness.run("""
		  window.__mdPlaceCaret(5, 1);
		  document.execCommand('insertText', false, '. ');
		  """)
		try await harness.waitQuiescent()
		#expect(harness.source == "Alpha Beta")
		try await harness.run("""
		  document.body.dispatchEvent(new KeyboardEvent('keydown', {
		    key: ' ', bubbles: true, cancelable: true
		  }));
		  """)
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()
		#expect(harness.source == "Alpha  Beta")
		try await harness.run("""
		  window.__mdPlaceCaret(7);
		  document.body.dispatchEvent(new KeyboardEvent('keydown', {key: '.', bubbles: true}));
		  document.execCommand('insertText', false, '.');
		  """)
		try await harness.waitForSourceEdits(3)
		#expect(harness.source == "Alpha  .Beta")
		try await assertHealthy(harness)
	}

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

	@Test func typingAndDeletingInATabbedRunPreservesTheTabWithoutRecovery() async throws {
		let source = "Alpha\tBeta\n\nTail"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.batch([
			"window.__mdPlaceCaret(2)",
			"document.execCommand('insertText', false, 'X')",
			"document.execCommand('insertText', false, '!')",
			"document.execCommand('insertText', false, '?')",
			"document.execCommand('insertText', false, 'Z')",
		])
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == "AlX!?Zpha\tBeta\n\nTail")
		try await assertHealthy(harness)

		try await harness.batch([
			"window.__mdPlaceCaret(2, 4)",
			"document.execCommand('delete')",
		])
		try await harness.waitForSourceEdits(3)
		#expect(harness.source == source)
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
		let mismatches = try await harness.stampMismatches()
		#expect(mismatches == [], Comment(rawValue: mismatches.joined(separator: "; ")))
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
		@Test func wordBackspaceDuringAWhitespaceRenderFreezeIsReplayed() async throws {
			let source = "eta ds alpha bravo"
			let harness = try await CoordinatorBridgeHarness(source: source)
			try await harness.batch([
				"window.__mdPlaceCaret(3)",
				"document.execCommand('insertText', false, ' ')",
				"window.__mdPlaceCaret(\((source as NSString).length + 1))",
				"""
				document.body.dispatchEvent(new InputEvent('beforeinput', {
				  inputType: 'deleteWordBackward', bubbles: true, cancelable: true
				}))
				""",
			])
			try await harness.waitForSourceEdits(2)
			try await harness.waitQuiescent()

			#expect(harness.source == "eta  ds alpha ")
			#expect(harness.coordinator.resyncCount == 0)
			#expect(try await harness.stampMismatches() == [])
		}

		@Test func wordForwardDeleteDuringAWhitespaceRenderFreezeIsReplayed() async throws {
			let source = "eta ds alpha bravo"
			let harness = try await CoordinatorBridgeHarness(source: source)
			let alpha = (source as NSString).range(of: "alpha").location + 1
			try await harness.batch([
				"window.__mdPlaceCaret(3)",
				"document.execCommand('insertText', false, ' ')",
				"window.__mdPlaceCaret(\(alpha))",
				"""
				document.body.dispatchEvent(new InputEvent('beforeinput', {
				  inputType: 'deleteWordForward', bubbles: true, cancelable: true
				}))
				""",
			])
			try await harness.waitForSourceEdits(2)
			try await harness.waitQuiescent()

			#expect(harness.source == "eta  ds  bravo")
			#expect(harness.coordinator.resyncCount == 0)
			#expect(try await harness.stampMismatches() == [])
		}

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
