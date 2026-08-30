//
//  EditBridgePasteTests.swift
//  MarkDownRangeTests
//
//  Paste, driven through WebKit's own editing pipeline on macOS: a real paste:
//  action off the general pasteboard, not a synthetic event. It takes the
//  verified structural route — splice the source, re-render — so what lands in
//  the DOM is always a render of text the source actually holds.
//
//  iOS drives the same contract from the page instead, because a library test
//  bundle has no UIApplication to route a responder action through. See
//  `CoordinatorBridgeHarness.clipboardCommand`.
//

#if os(macOS)
	import AppKit
#else
	import UIKit
#endif
import Testing
@testable import MarkDownRange

@Suite(.serialized) @MainActor struct EditBridgePasteTests {
	/// Puts `text` on the pasteboard for the duration of `body`, restoring
	/// whatever the user had there.
	private func withPasteboard(_ text: String, _ body: () async throws -> Void) async throws {
		await TestPasteboard.acquireExclusiveAccess()
		defer { TestPasteboard.releaseExclusiveAccess() }
		let saved = TestPasteboard.string
		defer {
			TestPasteboard.string = saved
		}
		TestPasteboard.string = text
		try await body()
	}

	private func withClearedPasteboard(_ body: () async throws -> Void) async throws {
		await TestPasteboard.acquireExclusiveAccess()
		defer { TestPasteboard.releaseExclusiveAccess() }
		let saved = TestPasteboard.string
		defer {
			TestPasteboard.string = saved
		}
		TestPasteboard.string = nil
		try await body()
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

	private func paste(into harness: CoordinatorBridgeHarness, at offset: Int) async throws {
		try await harness.placeCaret(offset)
		try await harness.clipboardCommand(.paste)
	}

	private func performResponderCommand(
		_ command: ClipboardCommand,
		in harness: CoordinatorBridgeHarness
	) async throws {
		try await harness.clipboardCommand(command)
	}

	private func restore(
		_ text: String,
		caret: Int,
		token: Int,
		in harness: CoordinatorBridgeHarness
	) {
		harness.focusWebView()
		harness.coordinator.parent = MarkdownWebView(
			text: text, theme: .default, fontSize: 14)
			.editable(true)
			.caretTarget(MarkdownCaretTarget(offset: caret, token: token))
			.onSourceEdit { [weak harness] newText, _ in
				harness?.recordExternalEdit(newText)
			}
		harness.coordinator.applyCaretTarget()
		harness.coordinator.load(into: harness.webView)
		harness.adoptHostText(text)
	}

	private func deleteIndentedSoftLineCharacter(
		in harness: CoordinatorBridgeHarness
	) async throws {
		try await harness.run("""
			window.__mdPlaceCaret(7, 1)
			var target = window.getSelection().getRangeAt(0).cloneRange()
			window.getSelection().collapseToStart()
			var deletion = new InputEvent('beforeinput', {
			  inputType: 'deleteContentForward', bubbles: true, cancelable: true
			})
			Object.defineProperty(deletion, 'getTargetRanges', {
			  value: function () { return [target] }
			})
			var allowed = document.body.dispatchEvent(deletion)
			if (allowed) {
			  target.deleteContents()
			  document.body.dispatchEvent(new InputEvent('input', {
			    inputType: 'deleteContentForward', bubbles: true
			  }))
			}
			""")
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
	}

	@Test func pasteAfterAnIndentedSoftLineDeletionUsesTheRestoredCaret() async throws {
		let harness = try await CoordinatorBridgeHarness(
			source: "Term\n  x: Definition\n\nTail")
		try await harness.run("""
			window.__mdPlaceCaret(7, 1)
			var target = window.getSelection().getRangeAt(0).cloneRange()
			window.getSelection().collapseToStart()
			var deletion = new InputEvent('beforeinput', {
			  inputType: 'deleteContentForward', bubbles: true, cancelable: true
			})
			Object.defineProperty(deletion, 'getTargetRanges', {
			  value: function () { return [target] }
			})
			var allowed = document.body.dispatchEvent(deletion)
			if (allowed) {
			  target.deleteContents()
			  document.body.dispatchEvent(new InputEvent('input', {
			    inputType: 'deleteContentForward', bubbles: true
			  }))
			}
			""")
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		try await withPasteboard("P") {
			try await performResponderCommand(.paste, in: harness)
			try await harness.waitForSourceEdits(2)
		}
		try await harness.waitQuiescent()

		#expect(harness.source == "Term\n  P: Definition\n\nTail")
		let fresh = try await CoordinatorBridgeHarness(source: harness.source)
		let liveVisible = EditBridgeFuzzTests.normalizedVisibleText(
			try await harness.domVisibleText())
		let freshVisible = EditBridgeFuzzTests.normalizedVisibleText(
			try await fresh.domVisibleText())
		#expect(liveVisible == freshVisible)
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func selectAllCopyAfterAnIndentedSoftLineDeletionDoesNotExposeTheCaretHome() async throws {
		let original = "Term\n  x: Definition\n\nTail"
		let expectedSource = "Term\n  : Definition\n\nTail"
		let harness = try await CoordinatorBridgeHarness(source: original)
		try await harness.run("""
			window.__mdPlaceCaret(7, 1)
			var target = window.getSelection().getRangeAt(0).cloneRange()
			window.getSelection().collapseToStart()
			var deletion = new InputEvent('beforeinput', {
			  inputType: 'deleteContentForward', bubbles: true, cancelable: true
			})
			Object.defineProperty(deletion, 'getTargetRanges', {
			  value: function () { return [target] }
			})
			var allowed = document.body.dispatchEvent(deletion)
			if (allowed) {
			  target.deleteContents()
			  document.body.dispatchEvent(new InputEvent('input', {
			    inputType: 'deleteContentForward', bubbles: true
			  }))
			}
			""")
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		#expect(try await harness.evaluate(
			"String(document.querySelectorAll('[data-md-inline-caret-home]').length)"
		) == "1")

		try await harness.run("document.execCommand('selectAll')")
		try await withClearedPasteboard {
			try await performResponderCommand(.copy, in: harness)
			try await harness.waitUntil("native Copy pasteboard delivery") {
				TestPasteboard.string != nil
			}
			let copied = try #require(TestPasteboard.string)
			#expect(!copied.contains("\u{200B}"),
				"clipboard exposed the DOM-only caret marker: \(copied.debugDescription)")
		}

		#expect(harness.source == expectedSource)
		#expect(harness.sourceEditCount == 1)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test(arguments: [
		(direction: "backward", copied: "a", expected: "Alph<u></u> Tail"),
		(direction: "forward", copied: " ", expected: "Alpha<u></u>Tail"),
	])
	func extendingASelectionFromAnEmptyUnderlineCaretOwnsOneVisibleCharacter(
		direction: String,
		copied: String,
		expected: String
	) async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha Tail")
		try await harness.batch([
			"window.__mdPlaceCaret(5)",
			"window.__mdApplyFormat('underline')",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		let key = direction == "backward" ? "ArrowLeft" : "ArrowRight"
		try await harness.run("""
			var arrow = new KeyboardEvent('keydown', {
			  key: '\(key)', shiftKey: true, bubbles: true, cancelable: true
			})
			if (document.body.dispatchEvent(arrow)) {
			  window.getSelection().modify('extend', '\(direction)', 'character')
			}
			""")

		try await withClearedPasteboard {
			try await performResponderCommand(.copy, in: harness)
			try await harness.waitUntil("native Copy pasteboard delivery") {
				TestPasteboard.string != nil
			}
			#expect(TestPasteboard.string == copied, "direction=\(direction)")
		}
		let selectedBeforeTyping = try await harness.evaluate("window.getSelection().toString()")
		#expect(selectedBeforeTyping == copied,
			"selection collapsed after Copy for direction=\(direction)")
		try await withClearedPasteboard {
			try await performResponderCommand(.cut, in: harness)
			try await harness.waitUntil("native Cut pasteboard delivery") {
				TestPasteboard.string != nil
			}
			#expect(TestPasteboard.string == copied, "direction=\(direction)")
		}
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()

		#expect(harness.source == expected, "direction=\(direction)")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test(arguments: [
		(direction: "backward", expected: "AlphP<u></u> Tail"),
		(direction: "forward", expected: "Alpha<u></u>PTail"),
	])
	func pasteOverASelectionExtendedFromAnEmptyUnderlineCaretReplacesVisibleText(
		direction: String,
		expected: String
	) async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha Tail")
		try await harness.batch([
			"window.__mdPlaceCaret(5)",
			"window.__mdApplyFormat('underline')",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		let key = direction == "backward" ? "ArrowLeft" : "ArrowRight"
		try await harness.run("""
			var arrow = new KeyboardEvent('keydown', {
			  key: '\(key)', shiftKey: true, bubbles: true, cancelable: true
			})
			if (document.body.dispatchEvent(arrow)) {
			  window.getSelection().modify('extend', '\(direction)', 'character')
			}
			""")

		try await withPasteboard("P") {
			try await performResponderCommand(.paste, in: harness)
			try await harness.waitForSourceEdits(2)
		}
		try await harness.waitQuiescent()

		#expect(harness.source == expected, "direction=\(direction)")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test(arguments: [
		(direction: "backward", copied: "ha", expected: "AlpP<u></u> Bravo"),
		(direction: "forward", copied: " B", expected: "Alpha<u></u>Pravo"),
	])
	func pasteOverTwoCharactersExtendedFromAnEmptyUnderlineCaret(
		direction: String,
		copied: String,
		expected: String
	) async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha Bravo")
		try await harness.batch([
			"window.__mdPlaceCaret(5)",
			"window.__mdApplyFormat('underline')",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		let key = direction == "backward" ? "ArrowLeft" : "ArrowRight"
		try await harness.run("""
			for (var index = 0; index < 2; index += 1) {
			  var arrow = new KeyboardEvent('keydown', {
			    key: '\(key)', shiftKey: true, bubbles: true, cancelable: true
			  })
			  if (document.body.dispatchEvent(arrow)) {
			    window.getSelection().modify('extend', '\(direction)', 'character')
			  }
			}
			""")

		#expect(try await harness.evaluate("window.getSelection().toString()") == copied,
			"direction=\(direction)")
		try await withPasteboard("P") {
			try await harness.run("""
				document.body.dispatchEvent(new InputEvent('beforeinput', {
				  inputType: 'insertFromPaste', bubbles: true, cancelable: true
				}))
				""")
			try await harness.waitForSourceEdits(2)
		}
		try await harness.waitQuiescent()

		#expect(harness.source == expected, "direction=\(direction)")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test(arguments: [
		(direction: "backward", copied: "a", expected: "AlphP<u></u> Tail"),
		(direction: "forward", copied: " ", expected: "Alpha<u></u>PTail"),
	])
	func pasteOverASelectionFromAHostRestoredPostWrapperCaretReplacesVisibleText(
		direction: String,
		copied: String,
		expected: String
	) async throws {
		let formatted = "Alpha<u></u> Tail"
		let harness = try await CoordinatorBridgeHarness(source: "Seed")
		harness.focusWebView()
		harness.coordinator.parent = MarkdownWebView(
			text: formatted, theme: .default, fontSize: 15)
			.editable(true)
			.caretTarget(MarkdownCaretTarget(offset: 12, token: 705))
			.onSourceEdit { [weak harness] newText, _ in
				harness?.recordExternalEdit(newText)
			}
		harness.coordinator.applyCaretTarget()
		harness.coordinator.load(into: harness.webView)
		harness.adoptHostText(formatted)
		try await harness.waitUntil("full-navigation post-wrapper caret") {
			try await harness.evaluate("""
				(function () {
				  var home = document.querySelector(
				    '[data-md-inline-caret-after-empty-wrapper]')
				  return home ? home.getAttribute('data-md-inline-caret-offset') : 'missing'
				})()
				""") == "12"
		}
		harness.rewireRoundTrip()
		let key = direction == "backward" ? "ArrowLeft" : "ArrowRight"
		try await harness.run("""
			var arrow = new KeyboardEvent('keydown', {
			  key: '\(key)', shiftKey: true, bubbles: true, cancelable: true
			})
			if (document.body.dispatchEvent(arrow)) {
			  window.getSelection().modify('extend', '\(direction)', 'character')
			}
			""")

		try await withClearedPasteboard {
			try await performResponderCommand(.copy, in: harness)
			try await harness.waitUntil("native Copy pasteboard delivery") {
				TestPasteboard.string != nil
			}
			#expect(TestPasteboard.string == copied, "direction=\(direction)")
		}
		#expect(try await harness.evaluate("window.getSelection().toString()") == copied)
		try await withPasteboard("P") {
			try await performResponderCommand(.paste, in: harness)
			try await harness.waitForSourceEdits(1)
		}
		try await harness.waitQuiescent()

		#expect(harness.source == expected, "direction=\(direction)")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test(arguments: [
		(source: "Alpha<u></u>  Bravo charlie", caret: 8,
		 direction: "forward", copied: "  Bravo",
		 expected: "Alpha<u></u>P charlie"),
		(source: "alpha Bravo<u></u> charlie", caret: 14,
		 direction: "backward", copied: "Bravo",
		 expected: "alpha P<u></u> charlie"),
		(source: "alpha **Bravo**<u></u> charlie", caret: 18,
		 direction: "backward", copied: "Bravo",
		 expected: "alpha P<u></u> charlie"),
		(source: "Alpha<u></u>  **Bravo** charlie", caret: 8,
		 direction: "forward", copied: "  Bravo",
		 expected: "Alpha<u></u>P charlie"),
		(source: "alpha ***Bravo***<u></u> charlie", caret: 20,
		 direction: "backward", copied: "Bravo",
		 expected: "alpha P<u></u> charlie"),
		(source: "Alpha<u></u>  Bravo charlie", caret: 12,
		 direction: "forward", copied: "  Bravo",
		 expected: "Alpha<u></u>P charlie"),
		(source: "alpha Bravo<u></u> charlie", caret: 18,
		 direction: "backward", copied: "Bravo",
		 expected: "alpha P<u></u> charlie"),
		(source: "alpha **Bravo**<u></u> charlie", caret: 22,
		 direction: "backward", copied: "Bravo",
		 expected: "alpha P<u></u> charlie"),
		(source: "A<u></u><u></u>  Bravo charlie", caret: 15,
		 direction: "forward", copied: "  Bravo",
		 expected: "A<u></u><u></u>P charlie"),
		(source: "Alpha<u></u>  **Bravo charlie** Delta", caret: 8,
		 direction: "forward", copied: "  Bravo",
		 expected: "Alpha<u></u>P **charlie** Delta"),
		(source: "alpha **Bravo charlie**<u></u> Delta", caret: 26,
		 direction: "backward", copied: "charlie",
		 expected: "alpha **Bravo P**<u></u> Delta"),
	])
	func optionShiftSelectionFromAnEmptyUnderlineCaretCopiesAndReplacesTheVisibleWord(
		source: String,
		caret: Int,
		direction: String,
		copied: String,
		expected: String
	) async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Seed")
		restore(source, caret: caret, token: 715, in: harness)
		try await harness.waitUntil("empty-wrapper word-selection caret") {
			try await harness.evaluate("""
				String(!!document.querySelector('[data-md-inline-caret-home]'))
				""") == "true"
		}
		harness.rewireRoundTrip()
		try await harness.run(
			"window.getSelection().modify('extend', '\(direction)', 'word')")

		try await withClearedPasteboard {
			try await performResponderCommand(.copy, in: harness)
			try await harness.waitUntil("word selection Copy pasteboard delivery") {
				TestPasteboard.string != nil
			}
			#expect(TestPasteboard.string == copied, "direction=\(direction)")
		}
		try await withPasteboard("P") {
			try await performResponderCommand(.paste, in: harness)
			try await harness.waitForSourceEdits(1)
		}
		try await harness.waitQuiescent()

		#expect(harness.source == expected, "direction=\(direction)")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test(arguments: [
		(source: "Alpha<u></u>  Bravo charlie", caret: 8,
		 direction: "forward", copied: "  Bravo",
		 expected: "Alpha<u></u> charlie"),
		(source: "alpha Bravo<u></u> charlie", caret: 14,
		 direction: "backward", copied: "Bravo",
		 expected: "alpha <u></u> charlie"),
		(source: "alpha **Bravo**<u></u> charlie", caret: 18,
		 direction: "backward", copied: "Bravo",
		 expected: "alpha <u></u> charlie"),
		(source: "Alpha<u></u>  **Bravo** charlie", caret: 8,
		 direction: "forward", copied: "  Bravo",
		 expected: "Alpha<u></u> charlie"),
		(source: "alpha ***Bravo***<u></u> charlie", caret: 20,
		 direction: "backward", copied: "Bravo",
		 expected: "alpha <u></u> charlie"),
		(source: "Alpha<u></u>  Bravo charlie", caret: 12,
		 direction: "forward", copied: "  Bravo",
		 expected: "Alpha<u></u> charlie"),
		(source: "alpha Bravo<u></u> charlie", caret: 18,
		 direction: "backward", copied: "Bravo",
		 expected: "alpha <u></u> charlie"),
		(source: "alpha **Bravo**<u></u> charlie", caret: 22,
		 direction: "backward", copied: "Bravo",
		 expected: "alpha <u></u> charlie"),
		(source: "A<u></u><u></u>  Bravo charlie", caret: 15,
		 direction: "forward", copied: "  Bravo",
		 expected: "A<u></u><u></u> charlie"),
		(source: "Alpha<u></u>  **Bravo charlie** Delta", caret: 8,
		 direction: "forward", copied: "  Bravo",
		 expected: "Alpha<u></u> **charlie** Delta"),
		(source: "alpha **Bravo charlie**<u></u> Delta", caret: 26,
		 direction: "backward", copied: "charlie",
		 expected: "alpha **Bravo** <u></u> Delta"),
	])
	func optionShiftCutFromAnEmptyUnderlineCaretDeletesOnlyTheVisibleWord(
		source: String,
		caret: Int,
		direction: String,
		copied: String,
		expected: String
	) async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Seed")
		restore(source, caret: caret, token: 716, in: harness)
		try await harness.waitUntil("empty-wrapper word-cut caret") {
			try await harness.evaluate("""
				String(!!document.querySelector('[data-md-inline-caret-home]'))
				""") == "true"
		}
		harness.rewireRoundTrip()
		try await harness.run(
			"window.getSelection().modify('extend', '\(direction)', 'word')")

		try await withClearedPasteboard {
			try await performResponderCommand(.cut, in: harness)
			try await harness.waitForSourceEdits(1)
			#expect(TestPasteboard.string == copied, "direction=\(direction)")
		}
		try await harness.waitQuiescent()

		#expect(harness.source == expected, "direction=\(direction)")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test(arguments: [
		(direction: "backward", copied: "A", expected: "P<u></u><u></u>B"),
		(direction: "forward", copied: "B", expected: "A<u></u><u></u>P"),
	])
	func pasteOverASelectionBesideAdjacentRestoredEmptyUnderlines(
		direction: String,
		copied: String,
		expected: String
	) async throws {
		let source = "A<u></u><u></u>B"
		let harness = try await CoordinatorBridgeHarness(source: "Seed")
		harness.focusWebView()
		harness.coordinator.parent = MarkdownWebView(
			text: source, theme: .default, fontSize: 15)
			.editable(true)
			.caretTarget(MarkdownCaretTarget(offset: 8, token: 712))
			.onSourceEdit { [weak harness] newText, _ in
				harness?.recordExternalEdit(newText)
			}
		harness.coordinator.applyCaretTarget()
		harness.coordinator.load(into: harness.webView)
		harness.adoptHostText(source)
		try await harness.waitUntil("adjacent empty-wrapper caret") {
			try await harness.evaluate("""
				(function () {
				  var home = document.querySelector('[data-md-inline-caret-home]')
				  return home ? home.getAttribute('data-md-inline-caret-offset') : 'missing'
				})()
				""") == "8"
		}
		harness.rewireRoundTrip()
		let key = direction == "backward" ? "ArrowLeft" : "ArrowRight"
		try await harness.run("""
			var arrow = new KeyboardEvent('keydown', {
			  key: '\(key)', shiftKey: true, bubbles: true, cancelable: true
			})
			if (document.body.dispatchEvent(arrow)) {
			  window.getSelection().modify('extend', '\(direction)', 'character')
			}
			""")
		#expect(try await harness.evaluate("window.getSelection().toString()") == copied,
			"direction=\(direction)")
		try await withPasteboard("P") {
			try await harness.run("""
				document.body.dispatchEvent(new ClipboardEvent('paste', {
				  bubbles: true, cancelable: true
				}))
				""")
			try await harness.waitForSourceEdits(1)
		}
		try await harness.waitQuiescent()

		#expect(harness.source == expected, "direction=\(direction)")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test(arguments: [
		(source: #"A \\<u></u> B"#, caret: 11, key: "ArrowLeft",
		 direction: "backward", copied: "\\", expected: "A P<u></u> B"),
		(source: #"A<u></u>\* B"#, caret: 8, key: "ArrowRight",
		 direction: "forward", copied: "*", expected: "A<u></u>P B"),
	])
	func pasteOverAnEscapedVisibleCharacterBesideAnEmptyUnderlineReplacesItsSourcePair(
		source: String,
		caret: Int,
		key: String,
		direction: String,
		copied: String,
		expected: String
	) async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Seed")
		harness.focusWebView()
		harness.coordinator.parent = MarkdownWebView(
			text: source, theme: .default, fontSize: 15)
			.editable(true)
			.caretTarget(MarkdownCaretTarget(offset: caret, token: 717))
			.onSourceEdit { [weak harness] newText, _ in
				harness?.recordExternalEdit(newText)
			}
		harness.coordinator.applyCaretTarget()
		harness.coordinator.load(into: harness.webView)
		harness.adoptHostText(source)
		try await harness.waitUntil("escaped-character wrapper caret") {
			try await harness.evaluate("""
				(function () {
				  var home = document.querySelector('[data-md-inline-caret-home]')
				  return home ? home.getAttribute('data-md-inline-caret-offset') : 'missing'
				})()
				""") == String(caret)
		}
		harness.rewireRoundTrip()
		try await harness.run("""
			var arrow = new KeyboardEvent('keydown', {
			  key: '\(key)', shiftKey: true, bubbles: true, cancelable: true
			})
			if (document.body.dispatchEvent(arrow)) {
			  window.getSelection().modify('extend', '\(direction)', 'character')
			}
			""")
		#expect(try await harness.evaluate("window.getSelection().toString()") == copied)
		try await withPasteboard("P") {
			try await harness.run("""
				document.body.dispatchEvent(new ClipboardEvent('paste', {
				  bubbles: true, cancelable: true
				}))
				""")
			try await harness.waitForSourceEdits(1)
		}
		try await harness.waitQuiescent()

		#expect(harness.source == expected, "direction=\(direction)")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test(arguments: [
		(pasted: "P", afterPaste: "Alpha<u></u>P Tail",
		 afterTyping: "Alpha<u></u>PX Tail"),
		(pasted: "One\n\nTwo", afterPaste: "Alpha<u></u>One\n\nTwo Tail",
		 afterTyping: "Alpha<u></u>One\n\nTwoX Tail"),
	])
	func pasteAtAHostRestoredPostWrapperCaretKeepsItsExactInsertionPoint(
		pasted: String,
		afterPaste: String,
		afterTyping: String
	) async throws {
		let formatted = "Alpha<u></u> Tail"
		let harness = try await CoordinatorBridgeHarness(source: "Seed")
		harness.focusWebView()
		harness.coordinator.parent = MarkdownWebView(
			text: formatted, theme: .default, fontSize: 15)
			.editable(true)
			.caretTarget(MarkdownCaretTarget(offset: 12, token: 706))
			.onSourceEdit { [weak harness] newText, _ in
				harness?.recordExternalEdit(newText)
			}
		harness.coordinator.applyCaretTarget()
		harness.coordinator.load(into: harness.webView)
		harness.adoptHostText(formatted)
		try await harness.waitUntil("full-navigation post-wrapper caret") {
			try await harness.evaluate("""
				(function () {
				  var home = document.querySelector(
				    '[data-md-inline-caret-after-empty-wrapper]')
				  return home ? home.getAttribute('data-md-inline-caret-offset') : 'missing'
				})()
				""") == "12"
		}
		harness.rewireRoundTrip()
		try await withPasteboard(pasted) {
			try await performResponderCommand(.paste, in: harness)
			try await harness.waitForSourceEdits(1)
		}
		try await harness.waitQuiescent()
		#expect(harness.source == afterPaste, "pasted=\(pasted.debugDescription)")
		try await harness.type("X")
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()

		#expect(harness.source == afterTyping, "pasted=\(pasted.debugDescription)")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func restoringACharacterCutBesideAnEmptyUnderlineKeepsTheCaretTypable() async throws {
		let formatted = "Alpha<u></u> Tail"
		let harness = try await CoordinatorBridgeHarness(source: "Alpha Tail")
		try await harness.batch([
			"window.__mdPlaceCaret(5)",
			"window.__mdApplyFormat('underline')",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		try await harness.run("""
			var arrow = new KeyboardEvent('keydown', {
			  key: 'ArrowRight', shiftKey: true, bubbles: true, cancelable: true
			})
			document.body.dispatchEvent(arrow)
			""")
		try await withClearedPasteboard {
			try await performResponderCommand(.cut, in: harness)
			try await harness.waitForSourceEdits(2)
		}
		try await harness.waitQuiescent()
		#expect(harness.source == "Alpha<u></u>Tail")
		try await harness.waitUntil("cut source rendered") {
			try await harness.domVisibleText()
				.replacingOccurrences(of: "\u{200B}", with: "")
				.contains("AlphaTail")
		}

		restore(formatted, caret: 12, token: 701, in: harness)
		try await harness.waitQuiescent()
		try await harness.waitUntil("restored source rendered") {
			try await harness.domVisibleText()
				.replacingOccurrences(of: "\u{200B}", with: "")
				.contains("Alpha Tail")
		}
		try await harness.waitUntil("caret restored after empty underline") {
			try await harness.evaluate("""
				(function () {
				  var selection = window.getSelection()
				  if (!selection || !selection.anchorNode) return 'missing'
				  var element = selection.anchorNode.nodeType === 1
				    ? selection.anchorNode : selection.anchorNode.parentElement
				  var home = element.closest('[data-md-inline-caret-home]')
				  return home ? home.getAttribute('data-md-inline-caret-offset') : 'missing'
				})()
				""") == "12"
		}
		harness.rewireRoundTrip()
		try await harness.type("X")
		try await harness.waitForSourceEdits(3)
		try await harness.waitQuiescent()
		try await harness.waitUntil("post-restore typing rendered") {
			try await harness.domVisibleText()
				.replacingOccurrences(of: "\u{200B}", with: "")
				.contains("AlphaX Tail")
		}

		#expect(harness.source == "Alpha<u></u>X Tail")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0,
			"resync=\(harness.coordinator.lastResyncReason ?? "none"), incidents=\(harness.coordinator.bridgeIncidents)")
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func fullNavigationRestoreForwardsTheEmptyWrapperCaretMetadata() async throws {
		let formatted = "<u></u>Tail"
		let harness = try await CoordinatorBridgeHarness(source: "Tail")
		harness.focusWebView()
		harness.coordinator.parent = MarkdownWebView(
			text: formatted, theme: .default, fontSize: 15)
			.editable(true)
			.caretTarget(MarkdownCaretTarget(offset: 3, token: 702))
			.onSourceEdit { [weak harness] newText, _ in
				harness?.recordExternalEdit(newText)
			}
		harness.coordinator.applyCaretTarget()
		harness.coordinator.load(into: harness.webView)
		harness.adoptHostText(formatted)

		try await harness.waitUntil("full-navigation empty-wrapper caret") {
			try await harness.evaluate("""
				(function () {
				  var selection = window.getSelection()
				  if (!selection || !selection.anchorNode) return 'missing'
				  var element = selection.anchorNode.nodeType === 1
				    ? selection.anchorNode : selection.anchorNode.parentElement
				  var home = element.closest('[data-md-inline-caret-source-neutral]')
				  return home ? home.getAttribute('data-md-inline-caret-offset') : 'missing'
				})()
				""") == "3"
		}
		harness.rewireRoundTrip()
		try await harness.type("X")
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		#expect(harness.source == "<u>X</u>Tail")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func selectAllCutAfterAnIndentedSoftLineDeletionRoundTripsWithoutCopyingTheCaretHome() async throws {
		let expectedSource = "Term\n  : Definition\n\nTail"
		let harness = try await CoordinatorBridgeHarness(
			source: "Term\n  x: Definition\n\nTail")
		try await harness.run("""
			window.__mdPlaceCaret(7, 1)
			var target = window.getSelection().getRangeAt(0).cloneRange()
			window.getSelection().collapseToStart()
			var deletion = new InputEvent('beforeinput', {
			  inputType: 'deleteContentForward', bubbles: true, cancelable: true
			})
			Object.defineProperty(deletion, 'getTargetRanges', {
			  value: function () { return [target] }
			})
			var allowed = document.body.dispatchEvent(deletion)
			if (allowed) {
			  target.deleteContents()
			  document.body.dispatchEvent(new InputEvent('input', {
			    inputType: 'deleteContentForward', bubbles: true
			  }))
			}
			""")
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		try await harness.run("document.execCommand('selectAll')")

		try await withClearedPasteboard {
			try await performResponderCommand(.cut, in: harness)
			try await harness.waitForSourceEdits(2)
			let copied = try #require(TestPasteboard.string)
			#expect(!copied.contains("\u{200B}"),
				"clipboard exposed the DOM-only caret marker: \(copied.debugDescription)")
			#expect(harness.source.isEmpty)
			let exactSource = try #require(MarkdownPasteboard.source)
			#expect(exactSource == expectedSource,
				"private clipboard source was \(exactSource.debugDescription)")
			try await harness.waitQuiescent()
			try await paste(into: harness, at: 0)
			try await harness.waitForSourceEdits(3)
		}

		#expect(harness.source == expectedSource)
		try await harness.waitQuiescent()
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func partialCrossRunCutThroughARestoredCaretHomeRoundTripsExactSource() async throws {
		let expectedSource = "Term\n  : Definition\n\nTail"
		let harness = try await CoordinatorBridgeHarness(
			source: "Term\n  x: Definition\n\nTail")
		try await deleteIndentedSoftLineCharacter(in: harness)
		try await harness.run("""
			var home = document.querySelector('[data-md-inline-caret-home]')
			var runs = home.closest('p').querySelectorAll(
			  '[data-s]:not([data-md-inline-caret-home])')
			var range = document.createRange()
			range.setStart(runs[0].firstChild, 2)
			range.setEnd(runs[1].firstChild, 5)
			var selection = window.getSelection()
			selection.removeAllRanges()
			selection.addRange(range)
			""")

		try await withClearedPasteboard {
			try await performResponderCommand(.cut, in: harness)
			try await harness.waitForSourceEdits(2)
			#expect(TestPasteboard.string == "rm : Def")
			#expect(MarkdownPasteboard.source == "rm\n  : Def")
			#expect(harness.source == "Teinition\n\nTail")
			try await harness.waitQuiescent()
			try await paste(into: harness, at: 2)
			try await harness.waitForSourceEdits(3)
		}

		#expect(harness.source == expectedSource)
		try await harness.waitQuiescent()
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func typingImmediatelyAfterPasteAtARestoredCaretHomeReplaysAfterThePaste() async throws {
		let harness = try await CoordinatorBridgeHarness(
			source: "Term\n  x: Definition\n\nTail")
		try await deleteIndentedSoftLineCharacter(in: harness)

		try await withPasteboard("P") {
			try await performResponderCommand(.paste, in: harness)
			try await harness.run("document.execCommand('insertText', false, 'Z')")
			try await harness.waitForSourceEdits(3)
		}
		try await harness.waitQuiescent()

		#expect(harness.source == "Term\n  PZ: Definition\n\nTail")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func selectAllCutFromAnEmptyUnderlineCaretKeepsPublicTextCleanAndRoundTripsSource() async throws {
		let formattedSource = "Alpha<u></u> Tail"
		let harness = try await CoordinatorBridgeHarness(source: "Alpha Tail")
		try await harness.batch([
			"window.__mdPlaceCaret(5)",
			"window.__mdApplyFormat('underline')",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		#expect(harness.source == formattedSource)
		#expect(try await harness.evaluate(
			"String(document.querySelectorAll('[data-md-inline-caret-source-neutral]').length)"
		) == "1")
		try await harness.run("document.execCommand('selectAll')")

		try await withClearedPasteboard {
			try await performResponderCommand(.cut, in: harness)
			try await harness.waitForSourceEdits(2)
			#expect(TestPasteboard.string == "Alpha Tail")
			#expect(MarkdownPasteboard.source == formattedSource)
			#expect(harness.source.isEmpty)
			try await harness.waitQuiescent()
			try await paste(into: harness, at: 0)
			try await harness.waitForSourceEdits(3)
		}

		#expect(harness.source == formattedSource)
		try await harness.waitQuiescent()
		try await harness.type("X")
		try await harness.waitForSourceEdits(4)
		try await harness.waitQuiescent()
		#expect(harness.source == formattedSource + "X")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func partialCrossBlockCutContainingAnEmptyWrapperRoundTripsExactSource() async throws {
		let source = "Before\n\nAlpha<u></u> Tail\n\nAfter"
		let nsSource = source as NSString
		let start = 2
		let end = nsSource.range(of: "After").location + 2
		let selectedSource = nsSource.substring(
			with: NSRange(location: start, length: end - start))
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await select(harness, start: start, length: end - start)

		try await withClearedPasteboard {
			try await performResponderCommand(.cut, in: harness)
			try await harness.waitForSourceEdits(1)
			#expect(TestPasteboard.string == "fore\n\nAlpha Tail\n\nAf")
			#expect(MarkdownPasteboard.source == selectedSource)
			#expect(harness.source == "Beter")
			try await harness.waitQuiescent()
			try await paste(into: harness, at: start)
			try await harness.waitForSourceEdits(2)
		}
		try await harness.waitQuiescent()
		#expect(harness.source == source)
		try await harness.type("X")
		try await harness.waitForSourceEdits(3)
		try await harness.waitQuiescent()

		#expect(harness.source == "Before\n\nAlpha<u></u> Tail\n\nAfXter")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test(arguments: [false, true])
	func multilinePasteOverAPartialCrossBlockSelectionContainingAnEmptyWrapper(
		backward: Bool
	) async throws {
		let source = "Before\n\nAlpha<u></u> Tail\n\nAfter"
		let nsSource = source as NSString
		let start = 2
		let end = nsSource.range(of: "After").location + 2
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await select(
			harness, start: start, length: end - start, backward: backward)

		try await withPasteboard("One\n\nTwo") {
			try await performResponderCommand(.paste, in: harness)
			try await harness.waitForSourceEdits(1)
		}
		try await harness.waitQuiescent()
		#expect(harness.source == "BeOne\n\nTwoter", "backward=\(backward)")
		try await harness.type("X")
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()

		#expect(harness.source == "BeOne\n\nTwoXter", "backward=\(backward)")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func pasteIntoAnEmptyUnderlineCaretKeepsThePasteUnderlinedAndTheCaretTypable() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha Tail")
		try await harness.batch([
			"window.__mdPlaceCaret(5)",
			"window.__mdApplyFormat('underline')",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		try await withPasteboard("P") {
			try await performResponderCommand(.paste, in: harness)
			try await harness.waitForSourceEdits(2)
		}
		try await harness.waitQuiescent()
		#expect(harness.source == "Alpha<u>P</u> Tail")
		try await harness.type("Z")
		try await harness.waitForSourceEdits(3)
		try await harness.waitQuiescent()

		#expect(harness.source == "Alpha<u>PZ</u> Tail")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func multiParagraphPasteAtAnEmptyUnderlineCaretExitsTheWrapperCleanly() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha Tail")
		try await harness.batch([
			"window.__mdPlaceCaret(5)",
			"window.__mdApplyFormat('underline')",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		try await withPasteboard("One\n\nTwo") {
			try await performResponderCommand(.paste, in: harness)
			try await harness.waitForSourceEdits(2)
		}
		try await harness.waitQuiescent()
		#expect(harness.source == "AlphaOne\n\nTwo Tail",
			"incidents: \(harness.coordinator.bridgeIncidents)")
		try await harness.type("Z")
		try await harness.waitForSourceEdits(3)
		try await harness.waitQuiescent()

		#expect(harness.source == "AlphaOne\n\nTwoZ Tail")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test(arguments: [
		"bold", "italic", "strikethrough", "inlineCode",
		"highlight", "superscript", "subscript", "link",
	])
	func multiParagraphPasteAtAnEmptyMarkdownFormatCaretExitsTheDelimitersCleanly(
		command: String
	) async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha Tail")
		try await harness.batch([
			"window.__mdPlaceCaret(5)",
			"window.__mdApplyFormat('\(command)')",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		try await withPasteboard("One\n\nTwo") {
			try await performResponderCommand(.paste, in: harness)
			try await harness.waitForSourceEdits(2)
		}
		try await harness.waitQuiescent()
		#expect(harness.source == "AlphaOne\n\nTwo Tail",
			"command \(command), incidents: \(harness.coordinator.bridgeIncidents)")
		try await harness.type("Z")
		try await harness.waitForSourceEdits(3)
		try await harness.waitQuiescent()

		#expect(harness.source == "AlphaOne\n\nTwoZ Tail")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func largeMultiBlockPasteOverASelectionPreservesTheLongTailAndNextCaret() async throws {
		let tail = (0..<400).map {
			"Tail paragraph \($0) with **style** and café 🙂."
		}.joined(separator: "\n\n")
		let source = "Intro\n\nreplace me\n\n" + tail
		let replaced = (source as NSString).range(of: "replace me")
		let payload = (0..<180).map {
			"Pasted block \($0) with [link](https://example.com/\($0))."
		}.joined(separator: "\n\n")
		let expected = (source as NSString).replacingCharacters(
			in: replaced, with: payload)
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await select(harness, start: replaced.location, length: replaced.length)

		try await withPasteboard(payload) {
			try await performResponderCommand(.paste, in: harness)
			try await harness.waitForSourceEdits(1)
		}
		try await harness.waitQuiescent()
		#expect(harness.source == expected)
		try await harness.type("Z")
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()

		let insertion = replaced.location + (payload as NSString).length
		let expectedAfterTyping = (expected as NSString).replacingCharacters(
			in: NSRange(location: insertion, length: 0), with: "Z")
		#expect(harness.source == expectedAfterTyping)
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	// MARK: Non-breaking spaces
	//
	// contentEditable renders a lone space as U+00A0 so layout can't collapse
	// it, and hands that to the clipboard. These live here rather than in their
	// own suite because they touch the same system pasteboard the tests above
	// do, and a separate suite races them.

	@Test func pastedTextNormalizesNonBreakingSpaces() async {
		await TestPasteboard.acquireExclusiveAccess()
		defer { TestPasteboard.releaseExclusiveAccess() }
		let saved = TestPasteboard.string
		defer { TestPasteboard.string = saved }

		TestPasteboard.string = "Alpha\u{00A0}bravo"
		#expect(MarkdownWebView.Coordinator.pasteboardText(foldingNewlines: false) == "Alpha bravo")
	}

	@Test func normalizationSurvivesTheTableCellFold() async {
		await TestPasteboard.acquireExclusiveAccess()
		defer { TestPasteboard.releaseExclusiveAccess() }
		let saved = TestPasteboard.string
		defer { TestPasteboard.string = saved }

		// Folding splits on newlines and trims; an NBSP is not whitespace to
		// `trimmingCharacters(in: .whitespaces)`'s eyes in the middle of a run,
		// so it has to be gone before the fold rather than after.
		TestPasteboard.string = "one\u{00A0}two\nthree"
		#expect(MarkdownWebView.Coordinator.pasteboardText(foldingNewlines: true) == "one two three")
	}

	@Test func matchStylePasteIgnoresTheSourceFaithfulFlavor() async {
		await TestPasteboard.acquireExclusiveAccess()
		defer { TestPasteboard.releaseExclusiveAccess() }
		let savedText = MarkdownPasteboard.substitute
		let savedSource = MarkdownPasteboard.sourceSubstitute
		defer {
			MarkdownPasteboard.substitute = savedText
			MarkdownPasteboard.sourceSubstitute = savedSource
		}
		MarkdownPasteboard.substitute = { "visible prose" }
		MarkdownPasteboard.sourceSubstitute = { "**visible prose**" }

		#expect(MarkdownWebView.Coordinator.pasteboardText(
			foldingNewlines: false, preferringSource: true) == "**visible prose**")
		#expect(MarkdownWebView.Coordinator.pasteboardText(
			foldingNewlines: false, preferringSource: false) == "visible prose")
	}

	@Test func pasteCaretArithmeticRejectsNegativeAndOverflowingStarts() {
		#expect(MarkdownWebView.Coordinator.caretAfterInsertion(start: -1, text: "X") == nil)
		#expect(MarkdownWebView.Coordinator.caretAfterInsertion(start: Int.max, text: "X") == nil)
		#expect(MarkdownWebView.Coordinator.caretAfterInsertion(start: 7, text: "😀") == 9)
	}

	@Test func delayedCutDoesNotAttachSourceToAChangedPasteboard() async {
		await TestPasteboard.acquireExclusiveAccess()
		defer { TestPasteboard.releaseExclusiveAccess() }
		let saved = TestPasteboard.string
		defer { TestPasteboard.string = saved }
		TestPasteboard.string = "new clipboard contents"

		let wrote = MarkdownPasteboard.writeSource(
			"**old selection**", ifTextMatches: "old selection")

		#expect(!wrote)
		#expect(TestPasteboard.source == nil)
	}

	@Test func delayedCutDoesNotIgnoreRemovedClipboardWhitespace() async {
		await TestPasteboard.acquireExclusiveAccess()
		defer { TestPasteboard.releaseExclusiveAccess() }
		let saved = TestPasteboard.string
		defer { TestPasteboard.string = saved }
		TestPasteboard.string = "oldselection"

		let wrote = MarkdownPasteboard.writeSource(
			"**old selection**", ifTextMatches: "old selection")

		#expect(!wrote)
		#expect(TestPasteboard.source == nil)
	}

	@Test func cuttingAndPastingASingleSpaceIsANoOp() async throws {
		await TestPasteboard.acquireExclusiveAccess()
		defer { TestPasteboard.releaseExclusiveAccess() }
		// Marker #3: the space between two words, cut and pasted straight back.
		let harness = try await CoordinatorBridgeHarness(source: "Alpha bravo charlie\n")
		let space = ("Alpha bravo charlie\n" as NSString).range(of: " ").location

		try await harness.run("window.__mdPlaceCaret(\(space), 1)")
		try await harness.clipboardCommand(.cut)
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "Alphabravo charlie\n")
		try await harness.waitQuiescent()

		try await harness.run("window.__mdPlaceCaret(\(space))")
		try await harness.clipboardCommand(.paste)
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == "Alpha bravo charlie\n")
		#expect(!harness.source.contains("\u{00A0}"), "a non-breaking space reached the source")
		try await harness.waitQuiescent()
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func cuttingAndPastingAWordInAHeadingAddsNoMarkup() async throws {
		await TestPasteboard.acquireExclusiveAccess()
		defer { TestPasteboard.releaseExclusiveAccess() }
		// Marker #4: the round trip is visually invisible but was writing
		// emphasis markers into the source.
		let source = "# Styled Clipboard Stress\n"
		let harness = try await CoordinatorBridgeHarness(source: source)
		let word = (source as NSString).range(of: "Clipboard")

		try await harness.run("window.__mdPlaceCaret(\(word.location), \(word.length))")
		try await harness.clipboardCommand(.cut)
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		try await harness.run("window.__mdPlaceCaret(\(word.location))")
		try await harness.clipboardCommand(.paste)
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()
		#expect(harness.source == source)
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func cuttingAndPastingABlockSeparatorKeepsTheBlocksApart() async throws {
		await TestPasteboard.acquireExclusiveAccess()
		defer { TestPasteboard.releaseExclusiveAccess() }
		// Marker #2: the blank line between a heading and the paragraph under
		// it, cut and pasted back. Joining them would turn two blocks into one.
		let source = "# Styled Clipboard Stress\n\nAlpha bravo charlie.\n"
		let harness = try await CoordinatorBridgeHarness(source: source)
		let separator = (source as NSString).range(of: "\n\n")

		try await harness.run("window.__mdPlaceCaret(\(separator.location), \(separator.length))")
		try await harness.clipboardCommand(.cut)
		try await harness.waitForSourceEdits(1)
		#expect(TestPasteboard.source == "\n\n")
		try await harness.waitQuiescent()

		try await harness.run("window.__mdPlaceCaret(\(separator.location))")
		try await harness.clipboardCommand(.paste)
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()
		#expect(harness.source == source)
		// Still a heading and a paragraph, not one run-on block.
		#expect(try await harness.evaluate("String(document.querySelectorAll('h1').length)") == "1")
		#expect(try await harness.evaluate("String(document.querySelectorAll('p').length)") == "1")
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func aLargeCutAndPasteLeavesNoExtraBlankLinesInTheDOM() async throws {
		await TestPasteboard.acquireExclusiveAccess()
		defer { TestPasteboard.releaseExclusiveAccess() }
		// Marker #5: the source round-tripped exactly but the render kept
		// visible blank lines the markdown doesn't have. Compare the live DOM
		// against a fresh render of the same source — the convergence oracle.
		let source = """
			> Quoted text with punctuation: commas, semicolons; and em dashes — intact.

			## Second Section

			Paragraph A: 0123456789 repeated 0123456789 repeated 0123456789.
			Paragraph B: Unicode café naïve emoji 🧪🚀 and symbols <>&.
			"""
		let harness = try await CoordinatorBridgeHarness(source: source)
		let ns = source as NSString
		let start = ns.range(of: "Second Section").location
		let length = ns.length - start

		try await harness.run("window.__mdPlaceCaret(\(start), \(length))")
		try await harness.clipboardCommand(.cut)
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		// The structural cut restores its insertion point at the expanded
		// source boundary. The old visible-text offset may no longer exist after
		// the heading marker is consumed, so moving back to that stale offset
		// would test an impossible caret rather than the reported round trip.
		try await harness.clipboardCommand(.paste)
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()
		#expect(harness.source == source)

		let live = try await harness.domProjectedText()
		let fresh = try await CoordinatorBridgeHarness(source: harness.source)
		#expect(live == (try await fresh.domProjectedText()), "the DOM kept blank lines the source doesn't have")
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func pastingPlainTextSplicesItAtTheCaret() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "alpha beta\n")
		try await withPasteboard("PASTED") {
			try await paste(into: harness, at: 5)
			try await harness.waitForSourceEdits(1)
		}
		#expect(harness.source == "alphaPASTED beta\n")
		#expect(harness.lastCaretHint == 11)
		#expect(harness.coordinator.hardRejections == 0)
		try await harness.waitQuiescent()
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func typingAfterAPasteContinuesFromTheRestoredCaret() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "alpha beta\n")
		try await withPasteboard("XY") {
			try await paste(into: harness, at: 5)
			try await harness.waitForSourceEdits(1)
		}
		try await harness.waitQuiescent()
		try await harness.type("Z")
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == "alphaXYZ beta\n")
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func pastingMultipleLinesBecomesRealBlocks() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "head\n")
		try await withPasteboard("one\n\ntwo") {
			try await paste(into: harness, at: 4)
			try await harness.waitForSourceEdits(1)
		}
		#expect(harness.source == "headone\n\ntwo\n")
		try await harness.waitQuiescent()
		// Re-rendered from the source: two paragraphs, both stamped correctly.
		#expect(try await harness.evaluate("String(document.querySelectorAll('p').length)") == "2")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func pastingOverASelectionReplacesIt() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "alpha bravo charlie\n")
		try await withPasteboard("X") {
			try await harness.run("""
				window.__mdPlaceCaret(6);
				var s = window.getSelection(); var r = s.getRangeAt(0).cloneRange();
				r.setEnd(r.startContainer, r.startOffset + 5); s.removeAllRanges(); s.addRange(r);
				""")
			try await harness.clipboardCommand(.paste)
			try await harness.waitForSourceEdits(1)
		}
		#expect(harness.source == "alpha X charlie\n")
		try await harness.waitQuiescent()
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func pasteUsesTheLiveSelectionWhenWebKitReportsACollapsedTarget() async throws {
		let source = "alpha bravo charlie\n"
		let bravo = (source as NSString).range(of: "bravo")
		for backward in [false, true] {
			let harness = try await CoordinatorBridgeHarness(source: source)
			try await select(
				harness,
				start: bravo.location,
				length: bravo.length,
				backward: backward)

			try await withPasteboard("X") {
				try await harness.run("""
					var live = window.getSelection().getRangeAt(0)
					var stale = document.createRange()
					stale.setStart(live.startContainer, live.startOffset)
					stale.collapse(true)
					var paste = new InputEvent('beforeinput', {
					  inputType: 'insertFromPaste', bubbles: true, cancelable: true
					})
					Object.defineProperty(paste, 'getTargetRanges', {
					  value: function () { return [stale] }
					})
					document.body.dispatchEvent(paste)
					""")
				try await harness.waitForSourceEdits(1)
			}

			#expect(harness.source == "alpha X charlie\n", "backward=\(backward)")
			#expect(harness.lastCaretHint == 7, "backward=\(backward)")
			try await harness.waitQuiescent()
			#expect(try await harness.stampMismatches() == [])
			#expect(harness.coordinator.resyncCount == 0)
			#expect(harness.coordinator.hardRejections == 0)
		}
	}

	@Test func pastingOverMultipleStyledRunsConsumesTheirHiddenSyntax() async throws {
		let source = "Before **Alpha** and _Beta_ after"
		let start = (source as NSString).range(of: "Alpha").location
		let beta = (source as NSString).range(of: "Beta")
		for backward in [false, true] {
			let harness = try await CoordinatorBridgeHarness(source: source)
			try await select(
				harness,
				start: start,
				length: beta.upperBound - start,
				backward: backward)

			try await withPasteboard("X") {
				try await harness.clipboardCommand(.paste)
				try await harness.waitForSourceEdits(1)
			}

			#expect(harness.source == "Before X after", "backward=\(backward)")
			#expect(harness.lastCaretHint == ("Before X" as NSString).length)
			try await harness.waitQuiescent()
			#expect(try await harness.stampMismatches() == [])
			#expect(harness.coordinator.resyncCount == 0)
			#expect(harness.coordinator.hardRejections == 0)
			try await harness.type("!")
			try await harness.waitForSourceEdits(2)
			#expect(harness.source == "Before X! after", "backward=\(backward)")
		}
	}

	@Test func pastingOverAWholePrefixedBlockPreservesItsHiddenPrefix() async throws {
		let cases = [
			(source: "# Alpha\n\nTail", expected: "# X\n\nTail", caret: 3),
			(source: "> Alpha\n\nTail", expected: "> X\n\nTail", caret: 3),
			(source: "- Alpha\n\nTail", expected: "- X\n\nTail", caret: 3),
			(source: "1. Alpha\n\nTail", expected: "1. X\n\nTail", caret: 4),
			(source: "- [ ] Alpha\n\nTail", expected: "- [ ] X\n\nTail", caret: 7),
		]
		for item in cases {
			let alpha = (item.source as NSString).range(of: "Alpha")
			let harness = try await CoordinatorBridgeHarness(source: item.source)
			try await select(harness, start: alpha.location, length: alpha.length)

			try await withPasteboard("X") {
				try await harness.clipboardCommand(.paste)
				try await harness.waitForSourceEdits(1)
			}

			#expect(harness.source == item.expected, "source=\(item.source)")
			#expect(harness.lastCaretHint == item.caret)
			try await harness.waitQuiescent()
			#expect(try await harness.stampMismatches() == [])
			#expect(harness.coordinator.resyncCount == 0)
			#expect(harness.coordinator.hardRejections == 0)
		}
	}

	@Test func pastingOverOneStyledRunPreservesItsFormatting() async throws {
		let cases = [
			(source: "**Alpha** Tail", expected: "**X** Tail", caret: 3),
			(source: "_Alpha_ Tail", expected: "_X_ Tail", caret: 2),
			(source: "[Alpha](https://example.com) Tail", expected: "[X](https://example.com) Tail", caret: 2),
			(source: "[**Alpha**](https://example.com) Tail", expected: "[**X**](https://example.com) Tail", caret: 4),
		]
		for item in cases {
			let alpha = (item.source as NSString).range(of: "Alpha")
			let harness = try await CoordinatorBridgeHarness(source: item.source)
			try await select(harness, start: alpha.location, length: alpha.length)

			try await withPasteboard("X") {
				try await harness.clipboardCommand(.paste)
				try await harness.waitForSourceEdits(1)
			}

			#expect(harness.source == item.expected, "source=\(item.source)")
			#expect(harness.lastCaretHint == item.caret)
			try await harness.waitQuiescent()
			#expect(try await harness.stampMismatches() == [])
			#expect(harness.coordinator.resyncCount == 0)
			#expect(harness.coordinator.hardRejections == 0)
		}
	}

	@Test func multiParagraphPasteOverAWholeStyledRunExitsItsInlineSyntax() async throws {
		let cases = [
			(source: "**Alpha** Tail", expected: "One\n\nTwo Tail"),
			(source: "_Alpha_ Tail", expected: "One\n\nTwo Tail"),
			(source: "~~Alpha~~ Tail", expected: "One\n\nTwo Tail"),
			(source: "`Alpha` Tail", expected: "One\n\nTwo Tail"),
			(source: "==Alpha== Tail", expected: "One\n\nTwo Tail"),
			(source: "^Alpha^ Tail", expected: "One\n\nTwo Tail"),
			(source: "~Alpha~ Tail", expected: "One\n\nTwo Tail"),
			(source: "<u>Alpha</u> Tail", expected: "One\n\nTwo Tail"),
			(source: "[Alpha](https://example.com) Tail", expected: "One\n\nTwo Tail"),
			(source: "[**Alpha**](https://example.com) Tail", expected: "One\n\nTwo Tail"),
		]
		for (index, item) in cases.enumerated() {
			let alpha = (item.source as NSString).range(of: "Alpha")
			let harness = try await CoordinatorBridgeHarness(source: item.source)
			try await select(
				harness,
				start: alpha.location,
				length: alpha.length,
				backward: index.isMultiple(of: 2))

			try await withPasteboard("One\n\nTwo") {
				try await harness.clipboardCommand(.paste)
				try await harness.waitForSourceEdits(1)
			}

			#expect(harness.source == item.expected,
				"source=\(item.source), incidents=\(harness.coordinator.bridgeIncidents)")
			try await harness.type("Z")
			try await harness.waitForSourceEdits(2)
			try await harness.waitQuiescent()
			#expect(harness.source == "One\n\nTwoZ Tail", "source=\(item.source)")
			#expect(try await harness.stampMismatches() == [])
			#expect(harness.coordinator.resyncCount == 0)
			#expect(harness.coordinator.hardRejections == 0)
		}
	}

	@Test func multiParagraphPasteInsideAStyledRunKeepsUntouchedFragmentsStyled() async throws {
		let cases = [
			(source: "**Alpha** Tail", selected: "ph",
			 expected: "**Al**One\n\nTwo**a** Tail"),
			(source: "**Alpha** Tail", selected: "Al",
			 expected: "One\n\nTwo**pha** Tail"),
			(source: "**Alpha** Tail", selected: "ha",
			 expected: "**Alp**One\n\nTwo Tail"),
			(source: "[Alpha](https://example.com) Tail", selected: "ph",
			 expected: "[Al](https://example.com)One\n\nTwo[a](https://example.com) Tail"),
			(source: "[**Alpha**](https://example.com) Tail", selected: "ph",
			 expected: "[**Al**](https://example.com)One\n\nTwo[**a**](https://example.com) Tail"),
		]
		for (index, item) in cases.enumerated() {
			let selected = (item.source as NSString).range(of: item.selected)
			let harness = try await CoordinatorBridgeHarness(source: item.source)
			try await select(
				harness,
				start: selected.location,
				length: selected.length,
				backward: index.isMultiple(of: 2))

			try await withPasteboard("One\n\nTwo") {
				try await harness.clipboardCommand(.paste)
				try await harness.waitForSourceEdits(1)
			}
			try await harness.waitQuiescent()

			#expect(harness.source == item.expected,
				"source=\(item.source), selected=\(item.selected)")
			try await harness.type("Z")
			try await harness.waitForSourceEdits(2)
			try await harness.waitQuiescent()
			#expect(harness.source.contains("TwoZ"), "source=\(item.source)")
			#expect(try await harness.stampMismatches() == [])
			#expect(harness.coordinator.resyncCount == 0)
			#expect(harness.coordinator.hardRejections == 0)
		}
	}

	@Test func pastingMarkdownKeepsItAsSourceNotAsMarkup() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "head\n")
		try await withPasteboard("**bold**") {
			try await paste(into: harness, at: 4)
			try await harness.waitForSourceEdits(1)
		}
		#expect(harness.source == "head**bold**\n")
		try await harness.waitQuiescent()
		// The markers reached the source, so the render shows real bold — and
		// the DOM has no styling the source can't account for.
		#expect(try await harness.evaluate("String(document.querySelectorAll('strong').length)") == "1")
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func pastingIntoATableCellFoldsLineBreaksIntoSpaces() async throws {
		// A newline inside a row would shatter the table, and a cell can't show
		// one anyway.
		let table = "| a | b |\n| --- | --- |\n| c | d |"
		let harness = try await CoordinatorBridgeHarness(source: table)
		try await withPasteboard("one\ntwo") {
			try await paste(into: harness, at: (table as NSString).range(of: "c").location + 1)
			try await harness.waitForSourceEdits(1)
		}
		#expect(harness.source == "| a | b |\n| --- | --- |\n| cone two | d |")
		try await harness.waitQuiescent()
		#expect(try await harness.evaluate("String(document.querySelectorAll('table').length)") == "1")
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func pastingWithNothingPastableThawsThePage() async throws {
		await TestPasteboard.acquireExclusiveAccess()
		defer { TestPasteboard.releaseExclusiveAccess() }
		// The page freezes before posting, so a paste the host can't fulfil must
		// still thaw it — otherwise typing stays silently dead until the
		// frozen-timeout safety net fires seconds later.
		let saved = TestPasteboard.string
		defer {
			TestPasteboard.string = saved
		}
		TestPasteboard.string = nil   // an empty pasteboard: nothing to paste

		let harness = try await CoordinatorBridgeHarness(source: "alpha beta\n")
		try await harness.placeCaret(5)
		try await harness.clipboardCommand(.paste)
		try await Task.sleep(for: .milliseconds(300))
		#expect(harness.source == "alpha beta\n")
		#expect(try await harness.evaluate("window.__mdIsFrozen() ? 'frozen' : 'live'") == "live")

		// And typing works immediately, without waiting for the timeout.
		try await harness.type("Q", at: 5)
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "alphaQ beta\n")
	}

	@Test func appKitResponderChainCutDeletesAForwardOrBackwardSelectionAndCopiesIt() async throws {
		let source = "Before [linked](https://example.com/a_(b)) and **bold** after Tail"
		let selectedSource = "Before [linked](https://example.com/a_(b)) and **bold** after"
		let range = (source as NSString).range(of: selectedSource)
		let expected = (source as NSString).replacingCharacters(in: range, with: "")
		for backward in [false, true] {
			let harness = try await CoordinatorBridgeHarness(source: source)
			try await select(harness, start: range.location, length: range.length, backward: backward)
			try await withClearedPasteboard {
				try await harness.clipboardCommand(.cut)
				try await harness.waitForSourceEdits(1)
				let copied = TestPasteboard.string ?? ""
				#expect(copied.contains("Before linked and bold after"))
			}
			#expect(harness.source == expected, "backward=\(backward)")
			#expect(harness.lastCaretHint == 0)
			try await harness.waitQuiescent()
			#expect(try await harness.stampMismatches() == [])
			#expect(harness.coordinator.resyncCount == 0)
			#expect(harness.coordinator.hardRejections == 0)
			try await harness.type("Q")
			try await harness.waitForSourceEdits(2)
			#expect(harness.source == "Q Tail")
		}
	}

	@Test func commandXDeletesASelectionInsideAFencedCodeBlock() async throws {
		let source = "```swift\nlet value = 1\nprint(value)\n```\n"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.run("""
			var code = document.querySelector('pre code')
			var range = document.createRange()
			range.selectNodeContents(code)
			var selection = window.getSelection()
			selection.removeAllRanges()
			selection.addRange(range)
			""")
		try await withClearedPasteboard {
			try await performResponderCommand(.cut, in: harness)
			try await harness.waitForSourceEdits(1)
			#expect(TestPasteboard.string?.contains("let value = 1") == true)
		}
		#expect(harness.source == "```swift\n```\n")
		try await harness.waitQuiescent()
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func appKitCutAcrossLazyContinuationAndHTMLBreakUsesTheRealPasteboardRoute() async throws {
		let source = """
		2. **Timeline** - route<br />
		This view is displayed when an item is selected. <br/>
		When an event is visible, the user can access the ArticlePage.

		Tail
		"""
		let selectedSource = """
		This view is displayed when an item is selected. <br/>
		When an event is visible, the user can access the
		"""
		let range = (source as NSString).range(of: selectedSource)
		let expected = (source as NSString).replacingCharacters(in: range, with: "")
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await select(harness, start: range.location, length: range.length)
		try await withClearedPasteboard {
			try await harness.clipboardCommand(.cut)
			try await harness.waitForSourceEdits(1)
			let copied = TestPasteboard.string ?? ""
			#expect(copied.contains("This view is displayed"))
			#expect(copied.contains("the user can access the"))
		}
		#expect(harness.source == expected)
		#expect(harness.lastCaretHint == range.location)
		try await harness.waitQuiescent()
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func responderCopyThenPasteDuplicatesAStyledSelectionWithoutCopyMutatingSource() async throws {
		let source = "Intro alpha **bold** and [link](https://example.com) tail"
		let selectedSource = "alpha **bold** and [link](https://example.com)"
		let range = (source as NSString).range(of: selectedSource)
		let destination = (source as NSString).range(of: "tail").location
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await select(harness, start: range.location, length: range.length)

		try await withClearedPasteboard {
			try await performResponderCommand(.copy, in: harness)
			try await harness.waitUntil("native Copy pasteboard delivery") {
				TestPasteboard.string != nil
			}
			#expect(harness.source == source)
			#expect(harness.sourceEditCount == 0)
			let copied = try #require(TestPasteboard.string)
			#expect(copied == "alpha bold and link")

			try await paste(into: harness, at: destination)
			try await harness.waitForSourceEdits(1)
			let expected = (source as NSString).replacingCharacters(
				in: NSRange(location: destination, length: 0), with: copied)
			#expect(harness.source == expected)
		}
		try await harness.waitQuiescent()
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func cutThenPasteMovesAChunkToANewPositionInTheSameRun() async throws {
		let source = "zero alpha beta gamma omega"
		let moved = "alpha beta "
		let range = (source as NSString).range(of: moved)
		let afterCut = (source as NSString).replacingCharacters(in: range, with: "")
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await select(harness, start: range.location, length: range.length, backward: true)

		try await withClearedPasteboard {
			try await performResponderCommand(.cut, in: harness)
			try await harness.waitForSourceEdits(1)
			#expect(harness.source == afterCut)
			#expect(TestPasteboard.string == moved)
			try await harness.waitQuiescent()

			let destination = (afterCut as NSString).range(of: "omega").location
			try await paste(into: harness, at: destination)
			try await harness.waitForSourceEdits(2)
			#expect(harness.source == "zero gamma alpha beta omega")
		}
		try await harness.waitQuiescent()
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func cutThenPasteMovesTextBetweenTableCellsWithoutDamagingPipes() async throws {
		let source = """
			| Name | Age |
			| --- | --- |
			| Alice | 30 |
			| Bob | 41 |
			"""
		let alice = (source as NSString).range(of: "Alice")
		let afterCut = (source as NSString).replacingCharacters(in: alice, with: "")
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await select(harness, start: alice.location, length: alice.length)

		try await withClearedPasteboard {
			try await performResponderCommand(.cut, in: harness)
			try await harness.waitForSourceEdits(1)
			#expect(harness.source == afterCut)
			#expect(TestPasteboard.string == "Alice")
			try await harness.waitQuiescent()

			let bob = (afterCut as NSString).range(of: "Bob")
			try await paste(into: harness, at: bob.location)
			try await harness.waitForSourceEdits(2)
			#expect(harness.source == """
				| Name | Age |
				| --- | --- |
				|  | 30 |
				| AliceBob | 41 |
				""")
		}
		try await harness.waitQuiescent()
		#expect(try await harness.evaluate("String(document.querySelectorAll('table').length)") == "1")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.source.split(separator: "\n").allSatisfy {
			$0.filter { $0 == "|" }.count == 3
		})
		// Cutting the cell down to "|  |" leaves two adjacent spaces, which is
		// the case iOS WebKit rebalances: the run comes back a character short
		// of the source it is stamped for, the queued edit's check catches it,
		// and the bridge resyncs from the spliced source rather than trusting a
		// DOM that has drifted. Everything that resync exists to protect is
		// asserted above — source, pipes, stamps, no hard rejections. WebKit may
		// rebalance this whitespace on either platform, but never needs more than
		// the one bounded repair.
		#expect(harness.coordinator.resyncCount <= 1)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func cutThenPasteMovesAMultiBlockChunkAndLeavesTheNextEditUsable() async throws {
		let source = "First paragraph\n\nSecond paragraph\n\nThird paragraph\n\nTail"
		let movedSource = "Second paragraph\n\nThird paragraph"
		let range = (source as NSString).range(of: movedSource)
		let afterCut = (source as NSString).replacingCharacters(in: range, with: "")
		let harness = try await CoordinatorBridgeHarness(source: source)
		var pasted = ""
		try await select(harness, start: range.location, length: range.length)

		try await withClearedPasteboard {
			try await performResponderCommand(.cut, in: harness)
			try await harness.waitForSourceEdits(1)
			#expect(harness.source == afterCut)
			let copied = try #require(TestPasteboard.string)
			pasted = copied
			#expect(copied.contains("Second paragraph"))
			#expect(copied.contains("Third paragraph"))
			try await harness.waitQuiescent()

			try await paste(into: harness, at: 0)
			try await harness.waitForSourceEdits(2)
			#expect(harness.source == copied + afterCut)
		}
		try await harness.waitQuiescent()
		try await harness.type("Q")
		try await harness.waitForSourceEdits(3)
		#expect(harness.source == pasted + "Q" + afterCut)
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func undoingAParagraphCutDoesNotCreateAStyledOnlyBlankParagraph() async throws {
		let source = "Intro\n\n**Chosen paragraph.**\n\n**Next paragraph.**"
		let chosenStart = (source as NSString).range(of: "**Chosen paragraph.**").location
		let harness = try await CoordinatorBridgeHarness(source: source)

		try await harness.run("""
			var paragraphs = document.querySelectorAll('p')
			var first = paragraphs[1].querySelector('[data-s]').firstChild
			var next = paragraphs[2].querySelector('[data-s]').firstChild
			var range = document.createRange()
			range.setStart(first, 0)
			range.setEnd(next, 0)
			var selection = window.getSelection()
			selection.removeAllRanges()
			selection.addRange(range)
			""")

		try await withClearedPasteboard {
			try await performResponderCommand(.cut, in: harness)
			try await harness.waitForSourceEdits(1)
			#expect(harness.source == "Intro\n\n**Next paragraph.**")
			try await harness.waitQuiescent()

			restore(source, caret: chosenStart, token: 1, in: harness)
			try await harness.waitQuiescent()
		}

		#expect(harness.source == source)
		#expect(try await harness.evaluate("""
			String(Array.from(document.body.children).filter(function (element) {
			  return element.tagName === 'P' && element.textContent.trim() === ''
			}).length)
			""") == "0")
		#expect(try await harness.evaluate("""
			Array.from(document.body.children).filter(function (element) {
			  return element.tagName === 'P'
			}).map(function (element) { return element.textContent }).join('|')
			""") == "Intro|Chosen paragraph.|Next paragraph.")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func selectAllResponderCutKeepsPlainTextExternalAndRoundTripsExactSource() async throws {
		let source = "# Heading\n\nAlpha **bold** text.\n\n> Quote\n\n- one\n- two"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.run("document.execCommand('selectAll')")

		try await withClearedPasteboard {
			try await performResponderCommand(.cut, in: harness)
			try await harness.waitForSourceEdits(1)
			#expect(harness.source.isEmpty)
			let copied = try #require(TestPasteboard.string)
			#expect(copied.contains("Heading"))
			#expect(copied.contains("Alpha bold text."))
			#expect(copied.contains("one"))
			try await harness.waitQuiescent()

			try await paste(into: harness, at: 0)
			try await harness.waitForSourceEdits(2)
			#expect(harness.source == source)
		}
		try await harness.waitQuiescent()
		try await harness.type("Q")
		try await harness.waitForSourceEdits(3)
		#expect(harness.source.hasSuffix("Q"))
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func pasteIssuedBeforeACutPatchSettlesIsIgnoredRatherThanAppliedAtStaleOffsets() async throws {
		let source = "zero **move-this** chunk omega"
		let moved = (source as NSString).range(of: "move-this")
		let afterCut = "zero  chunk omega"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await select(harness, start: moved.location, length: moved.length)

		try await withClearedPasteboard {
			try await performResponderCommand(.cut, in: harness)
			// The cut freezes the old DOM synchronously. A nearly simultaneous
			// paste must not address that old selection.
			try await performResponderCommand(.paste, in: harness)
			try await harness.waitForSourceEdits(1)
			try await Task.sleep(for: .milliseconds(150))
			#expect(harness.source == afterCut)
			#expect(harness.sourceEditCount == 1)
			#expect(TestPasteboard.string == "move-this")
			try await harness.waitQuiescent()

			let omega = (afterCut as NSString).range(of: "omega").location
			try await paste(into: harness, at: omega)
			try await harness.waitForSourceEdits(2)
			#expect(harness.source == "zero  chunk **move-this**omega")
		}
		try await harness.waitQuiescent()
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func immediatePasteAfterAPlainFastPathCutRoundTripsWithoutDivergence() async throws {
		let source = "zero move-this chunk omega"
		let moved = (source as NSString).range(of: "move-this ")
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await select(harness, start: moved.location, length: moved.length)

		try await withClearedPasteboard {
			try await performResponderCommand(.cut, in: harness)
			try await performResponderCommand(.paste, in: harness)
			try await harness.waitForSourceEdits(2)
			#expect(harness.source == source)
			#expect(TestPasteboard.string == "move-this ")
		}
		try await harness.waitQuiescent()
		try await harness.type("Q")
		try await harness.waitForSourceEdits(3)
		#expect(harness.source == "zero move-this Qchunk omega")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func pasteNormalizesMixedLineEndingsAndPreservesTabsAndUnicode() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Start\n")
		try await withPasteboard("\tTabbed\r\nLine 😀\rCombining e\u{301}") {
			try await paste(into: harness, at: 5)
			try await harness.waitForSourceEdits(1)
		}
		#expect(harness.source == "Start\tTabbed\nLine 😀\nCombining e\u{301}\n")
		try await harness.waitQuiescent()
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}
}
