//
//  EditBridgeNonStandardRouteTests.swift
//  FeltTipTests
//
//  Routes ordinary execCommand coverage does not reach: AppKit responder-chain
//  Cut, synthetic beforeinput target ranges/dataTransfer, blocked browser
//  commands, selections crossing read-only/table islands, composition over a
//  selection, selection mirroring reports, and commands racing a frozen patch.
//

#if os(macOS)
	import AppKit
#else
	import UIKit
#endif
import Foundation
import Testing
@testable import FeltTip

@Suite(.serialized) @MainActor struct EditBridgeNonStandardRouteTests {
	private func json(_ string: String) -> String {
		String(data: try! JSONEncoder().encode(string), encoding: .utf8)!
	}

	private func select(
		_ harness: CoordinatorBridgeHarness,
		start: Int,
		length: Int,
		backward: Bool = false
	) async throws {
		try await harness.run("""
			window.__mdPlaceCaret(\(start), \(length))
			\(backward ? """
			var selectedRange = window.getSelection().getRangeAt(0).cloneRange()
			window.getSelection().setBaseAndExtent(selectedRange.endContainer, selectedRange.endOffset, selectedRange.startContainer, selectedRange.startOffset)
			""" : "")
			""")
	}

	private func assertHealthy(
		_ harness: CoordinatorBridgeHarness,
		sourceLocation: SourceLocation = #_sourceLocation
	) async throws {
		try await harness.waitQuiescent()
		#expect(try await harness.stampMismatches() == [], sourceLocation: sourceLocation)
		#expect(harness.coordinator.resyncCount == 0, sourceLocation: sourceLocation)
		#expect(harness.coordinator.hardRejections == 0, sourceLocation: sourceLocation)
		#expect(harness.coordinator.bridgeIncidents == [], sourceLocation: sourceLocation)
	}

	@Test func dataTransferOnlyReplacementUsesItsStaticTargetRange() async throws {
		let source = "Alpha misspeled omega"
		let range = (source as NSString).range(of: "misspeled")
		let expected = (source as NSString).replacingCharacters(in: range, with: "misspelled")
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.run("""
			window.__mdPlaceCaret(\(range.location), \(range.length))
			var target = window.getSelection().getRangeAt(0).cloneRange()
			var replacement = new InputEvent('beforeinput', {
			  inputType: 'insertReplacementText', bubbles: true, cancelable: true
			})
			Object.defineProperty(replacement, 'getTargetRanges', { value: function () { return [target] } })
			Object.defineProperty(replacement, 'dataTransfer', {
			  value: { getData: function (kind) { return kind === 'text/plain' ? 'misspelled' : '' } }
			})
			var allowed = document.body.dispatchEvent(replacement)
			if (allowed) {
			  var node = target.startContainer
			  node.nodeValue = node.nodeValue.substring(0, target.startOffset)
			    + 'misspelled' + node.nodeValue.substring(target.endOffset)
			  document.body.dispatchEvent(new InputEvent('input', {
			    inputType: 'insertReplacementText', bubbles: true
			  }))
			}
			""")
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == expected)
		#expect(harness.lastCaretHint == range.location + 10)
		try await assertHealthy(harness)
	}

	@Test func nullReplacementPayloadIsBlockedWithoutFreezingThePage() async throws {
		let source = "Alpha beta omega"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.run("""
			window.__mdPlaceCaret(6, 4)
			var target = window.getSelection().getRangeAt(0).cloneRange()
			var replacement = new InputEvent('beforeinput', {
			  inputType: 'insertReplacementText', bubbles: true, cancelable: true
			})
			Object.defineProperty(replacement, 'getTargetRanges', { value: function () { return [target] } })
			window.__nullReplacementBlocked = !document.body.dispatchEvent(replacement)
			""")
		#expect(try await harness.evaluate("window.__nullReplacementBlocked ? 'yes' : 'no'") == "yes")
		#expect(try await harness.evaluate("window.__mdIsFrozen() ? 'yes' : 'no'") == "no")
		#expect(harness.source == source)
		try await harness.type("Q", at: 6)
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "Alpha Qbeta omega")
		try await assertHealthy(harness)
	}

	@Test func unsupportedBeforeInputCommandMatrixIsVetoedAndEditingStaysLive() async throws {
		let inputTypes = [
			"insertFromDrop", "deleteByDrag", "insertTranspose",
			"formatJustifyCenter", "insertOrderedList", "insertUnorderedList",
			"formatIndent", "formatOutdent", "insertHorizontalRule",
			"deleteSoftLineBackward", "deleteSoftLineForward",
			"deleteEntireSoftLine", "insertFromYank", "insertLink",
			"formatSetBlockTextDirection", "formatSetInlineTextDirection",
			"historyUndo", "historyRedo",
		]
		for inputType in inputTypes {
			let source = "Alpha beta\n\n- one\n- two"
			let harness = try await CoordinatorBridgeHarness(source: source)
			try await harness.run("""
				window.__mdPlaceCaret(6, 4)
				var event = new InputEvent('beforeinput', {
				  inputType: \(json(inputType)), bubbles: true, cancelable: true, data: 'DROP'
				})
				var selected = window.getSelection().getRangeAt(0).cloneRange()
				Object.defineProperty(event, 'getTargetRanges', { value: function () { return [selected] } })
				window.__unsupportedBlocked = !document.body.dispatchEvent(event)
				""")
			#expect(try await harness.evaluate("window.__unsupportedBlocked ? 'yes' : 'no'") == "yes",
					"inputType=\(inputType)")
			#expect(harness.source == source, "inputType=\(inputType)")
			#expect(harness.sourceEditCount == 0, "inputType=\(inputType)")
			#expect(try await harness.evaluate("window.__mdIsFrozen() ? 'yes' : 'no'") == "no")
			try await harness.type("Q", at: 1)
			try await harness.waitForSourceEdits(1)
			#expect(harness.source == "AQlpha beta\n\n- one\n- two")
			try await assertHealthy(harness)
		}
	}

	@Test func staticTargetWordDeletionRoutesApplyExactlyAndRemainEditable() async throws {
		for (inputType, caretAtEnd) in [
			("deleteWordBackward", true),
			("deleteWordForward", false),
		] {
			let source = "alpha one-two café omega"
			let deleted = (source as NSString).range(of: "one-two ")
			let expected = (source as NSString).replacingCharacters(in: deleted, with: "")
			let harness = try await CoordinatorBridgeHarness(source: source)
			try await harness.run("""
				window.__mdPlaceCaret(\(deleted.location), \(deleted.length))
				var target = window.getSelection().getRangeAt(0).cloneRange()
				window.__mdPlaceCaret(\(caretAtEnd ? deleted.upperBound : deleted.location))
				var deletion = new InputEvent('beforeinput', {
				  inputType: \(json(inputType)), bubbles: true, cancelable: true
				})
				Object.defineProperty(deletion, 'getTargetRanges', {
				  value: function () { return [target] }
				})
				var allowed = document.body.dispatchEvent(deletion)
				if (allowed) {
				  target.deleteContents()
				  document.body.dispatchEvent(new InputEvent('input', {
				    inputType: \(json(inputType)), bubbles: true
				  }))
				}
				""")
			try await harness.waitForSourceEdits(1)
			#expect(harness.source == expected, "inputType=\(inputType)")
			#expect(harness.lastCaretHint == deleted.location, "inputType=\(inputType)")
			try await assertHealthy(harness)
			try await harness.type("Q")
			try await harness.waitForSourceEdits(2)
			#expect(harness.source == "alpha Qcafé omega", "inputType=\(inputType)")
		}
	}

	@Test func selectionTouchingAReadOnlyCodeIslandCannotMutateEitherProjection() async throws {
		let source = "Alpha paragraph\n\n```swift\nlet x = 1\n```\n\nTail"
		let commands = [
			"document.execCommand('insertText', false, 'X')",
			"document.execCommand('delete')",
			"""
			var cut = new InputEvent('beforeinput', {
			  inputType: 'deleteByCut', bubbles: true, cancelable: true
			})
			document.body.dispatchEvent(cut)
			""",
			"document.execCommand('bold')",
			"window.__mdApplyFormat('highlight')",
			"document.execCommand('insertParagraph')",
			"document.execCommand('insertLineBreak')",
		]
		for command in commands {
			let harness = try await CoordinatorBridgeHarness(source: source)
			try await harness.run("""
				var paragraph = document.querySelector('p [data-s]')
				var pre = document.querySelector('pre')
				var walker = document.createTreeWalker(pre, NodeFilter.SHOW_TEXT)
				var code = walker.nextNode()
				var range = document.createRange()
				range.setStart(paragraph.firstChild, 2)
				range.setEnd(code, Math.min(3, code.nodeValue.length))
				var selection = window.getSelection()
				selection.removeAllRanges()
				selection.addRange(range)
				\(command)
				""")
			try await Task.sleep(for: .milliseconds(200))
			#expect(harness.source == source, "command=\(command)")
			#expect(harness.sourceEditCount == 0, "command=\(command)")
			#expect(harness.coordinator.hardRejections == 0, "command=\(command)")
			#expect(try await harness.evaluate("window.__mdIsFrozen() ? 'yes' : 'no'") == "no")
			try await harness.type("Q", at: 1)
			try await harness.waitForSourceEdits(1)
			#expect(harness.source == "AQlpha paragraph\n\n```swift\nlet x = 1\n```\n\nTail")
			try await assertHealthy(harness)
		}
	}

	@Test func selectionSpanningEveryReadOnlyIslandKindCannotDeleteAndEditingRecovers() async throws {
		let fixtures: [(name: String, selector: String, source: String)] = [
			(
				"alert", ".alert",
				"Before\n\n> [!NOTE]\n> Important information\n\nAfter"),
			(
				"details", "details",
				"Before\n\n<details>\n<summary>More</summary>\n\nBody\n\n</details>\n\nAfter"),
			(
				"frontmatter", ".frontmatter",
				"---\ntitle: Test\n---\n\nBefore\n\nAfter"),
			(
				"image", "img",
				"Before\n\n![Alt](missing.png)\n\nAfter"),
			(
				"thematic break", "hr",
				"Before\n\n---\n\nAfter"),
		]
		for fixture in fixtures {
			let harness = try await CoordinatorBridgeHarness(source: fixture.source)
			#expect(
				try await harness.evaluate(
					"document.querySelector(\(json(fixture.selector))) ? 'yes' : 'no'") == "yes",
				"missing \(fixture.name) fixture")
			try await harness.run("""
				var range = document.createRange()
				range.selectNodeContents(document.body)
				var selection = window.getSelection()
				selection.removeAllRanges()
				selection.addRange(range)
				document.execCommand('delete')
				""")
			try await Task.sleep(for: .milliseconds(150))
			#expect(harness.source == fixture.source, "island=\(fixture.name)")
			#expect(harness.sourceEditCount == 0, "island=\(fixture.name)")
			#expect(
				try await harness.evaluate("window.__mdIsFrozen() ? 'yes' : 'no'") == "no",
				"island=\(fixture.name)")

			let after = (fixture.source as NSString).range(of: "After").upperBound
			let stampDump = try await harness.evaluate("""
				Array.from(document.querySelectorAll('[data-s]')).map(function (run) {
				  return run.getAttribute('data-s') + ':' + run.textContent
				    + ':' + (run.closest('details') ? 'details' : 'editable')
				}).join('|')
				""") ?? ""
			try await harness.type("Q", at: after)
			try await harness.waitForSourceEdits(1)
			#expect(
				harness.source == fixture.source + "Q",
				"island=\(fixture.name), after=\(after), stamps=\(stampDump)")
			try await assertHealthy(harness)
		}
	}

	@Test func crossCellSelectionReplacementIsBlockedBeforeItCanEatTablePipes() async throws {
		let source = "| Name | Age |\n| --- | --- |\n| Alice | 30 |\n| Bob | 41 |"
		let start = (source as NSString).range(of: "Alice").location
		let end = (source as NSString).range(of: "30").upperBound
		let commands = [
			"document.execCommand('insertText', false, 'X')",
			"document.execCommand('delete')",
			"""
			var cut = new InputEvent('beforeinput', {
			  inputType: 'deleteByCut', bubbles: true, cancelable: true
			})
			document.body.dispatchEvent(cut)
			""",
			"document.execCommand('bold')",
			"window.__mdApplyFormat('highlight')",
			"document.execCommand('insertParagraph')",
			"document.execCommand('insertLineBreak')",
		]
		for command in commands {
			let harness = try await CoordinatorBridgeHarness(source: source)
			try await select(harness, start: start, length: end - start)
			try await harness.run(command)
			try await Task.sleep(for: .milliseconds(200))
			#expect(harness.source == source,
					"a cross-cell selection must not remove pipe syntax: \(command)")
			#expect(harness.sourceEditCount == 0, "command=\(command)")
			#expect(harness.coordinator.hardRejections == 0, "command=\(command)")
			#expect(try await harness.evaluate("window.__mdIsFrozen() ? 'yes' : 'no'") == "no")
			try await harness.type("Q", at: (source as NSString).range(of: "Bob").upperBound)
			try await harness.waitForSourceEdits(1)
			#expect(harness.source == "| Name | Age |\n| --- | --- |\n| Alice | 30 |\n| BobQ | 41 |")
			try await assertHealthy(harness)
		}
	}

	@Test func compositionReplacingASelectionPublishesOneWholeRunEdit() async throws {
		let source = "Alpha misspeled omega\n\nTail"
		let harness = try await CoordinatorBridgeHarness(source: source)
		let range = (source as NSString).range(of: "misspeled")
		try await harness.batch([
			"window.__mdPlaceCaret(\(range.location), \(range.length))",
			"document.body.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }))",
			"document.execCommand('insertText', false, 'misspelled')",
			"document.body.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: 'misspelled' }))",
		])
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "Alpha misspelled omega\n\nTail")
		#expect(harness.sourceEditCount == 1)
		try await assertHealthy(harness)
		try await harness.type("Q", at: (harness.source as NSString).range(of: "Tail").location)
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == "Alpha misspelled omega\n\nQTail")
	}

	@Test func compositionWithAstralAndCombiningTextKeepsLaterUTF16OffsetsExact() async throws {
		let source = "Alpha old omega\n\nTail 😀"
		let replacement = "👩‍💻e\u{301}"
		let harness = try await CoordinatorBridgeHarness(source: source)
		let range = (source as NSString).range(of: "old")
		try await harness.batch([
			"window.__mdPlaceCaret(\(range.location), \(range.length))",
			"document.body.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }))",
			"document.execCommand('insertText', false, '\(replacement)')",
			"""
			document.body.dispatchEvent(new CompositionEvent('compositionend', {
			  bubbles: true, data: '\(replacement)'
			}))
			""",
		])
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "Alpha \(replacement) omega\n\nTail 😀")
		#expect(harness.sourceEditCount == 1)
		try await assertHealthy(harness)

		let tail = (harness.source as NSString).range(of: "Tail 😀").upperBound
		try await harness.type("Q", at: tail)
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == "Alpha \(replacement) omega\n\nTail 😀Q")
		try await assertHealthy(harness)
	}

	@Test func activeSelectionCannotOverwriteAHostUpdateFromTheOtherPane() async throws {
		let original = "Alpha beta\n\nTail"
		let newer = "Host changed alpha beta\n\nTail"
		let harness = try await CoordinatorBridgeHarness(source: original)
		try await select(harness, start: 0, length: 5)
		try await harness.replaceExternally(newer)
		// The old page is frozen synchronously when the host update is
		// scheduled. A command against its still-visible selection must die.
		try await harness.run("document.execCommand('insertText', false, 'STALE')")
		try await harness.waitQuiescent()
		#expect(harness.source == newer)
		#expect(harness.sourceEditCount == 0)
		#expect(harness.coordinator.resyncCount == 0)
		try await harness.type("Q", at: 0)
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "Q" + newer)
		try await assertHealthy(harness)
	}

	@Test func cutAndImmediateTypingReplaysAgainstTheRestoredCaret() async throws {
		let source = "Alpha **bold** beta\n\nTail"
		let selected = "Alpha **bold** beta"
		let range = (source as NSString).range(of: selected)
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await select(harness, start: range.location, length: range.length)
		try await harness.run("""
			var cut = new InputEvent('beforeinput', {
			  inputType: 'deleteByCut', bubbles: true, cancelable: true
			})
			document.body.dispatchEvent(cut)
			document.execCommand('insertText', false, 'STALE')
			""")
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == "STALE\n\nTail")
		#expect(harness.sourceEditCount == 2)
		try await assertHealthy(harness)
		try await harness.type("Q")
		try await harness.waitForSourceEdits(3)
		#expect(harness.source == "STALEQ\n\nTail")
	}

	@Test func forwardAndBackwardSelectionReportsUseTheSameSourceRange() async throws {
		let source = """
		2. **Timeline** - route<br />
		First continuation line.<br/>
		Second continuation line.

		Tail
		"""
		let selected = "First continuation line.<br/>\nSecond"
		let range = (source as NSString).range(of: selected)
		let harness = try await CoordinatorBridgeHarness(source: source)
		harness.focusWebView()
		// The test runner is not the active macOS application, so its
		// offscreen WKWebView reports document.hasFocus() == false. Override
		// only that focus oracle; the real debounce and range mapping remain.
		try await harness.run("""
			Object.defineProperty(document, 'hasFocus', {
			  configurable: true, value: function () { return true }
			})
			""")

		for backward in [false, true] {
			let previousCount = harness.selectionReportCount
			try await select(harness, start: range.location, length: range.length, backward: backward)
			try await harness.run("document.dispatchEvent(new Event('selectionchange'))")
			// Wait for a report that actually carries a range, not merely for
			// the counter to move: iOS WebKit emits extra selectionchange
			// events around a programmatic selection, and the first of them
			// can land before the selection exists. macOS emits one.
			try await harness.waitUntil("selection report") {
				harness.selectionReportCount > previousCount
					&& harness.lastReportedSelection != nil
			}
			#expect(harness.lastReportedSelection == range, "backward=\(backward)")
		}

		let previousCount = harness.selectionReportCount
		try await harness.placeCaret(range.location)
		try await harness.run("document.dispatchEvent(new Event('selectionchange'))")
		try await harness.waitUntil("collapsed selection report") {
			harness.selectionReportCount > previousCount
		}
		#expect(harness.lastReportedSelection == nil)
		#expect(harness.source == source)
	}
}
