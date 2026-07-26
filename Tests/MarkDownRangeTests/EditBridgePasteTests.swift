//
//  EditBridgePasteTests.swift
//  MarkDownRangeTests
//
//  Paste, driven through WebKit's own editing pipeline: a real paste: action
//  off the general pasteboard, not a synthetic event. It takes the verified
//  structural route — splice the source, re-render — so what lands in the DOM
//  is always a render of text the source actually holds.
//

#if os(macOS)
import AppKit
import Testing
@testable import MarkDownRange

@Suite(.serialized) @MainActor struct EditBridgePasteTests {
	/// Puts `text` on the pasteboard for the duration of `body`, restoring
	/// whatever the user had there.
	private func withPasteboard(_ text: String, _ body: () async throws -> Void) async throws {
		let pasteboard = NSPasteboard.general
		let saved = pasteboard.string(forType: .string)
		defer {
			pasteboard.clearContents()
			if let saved { pasteboard.setString(saved, forType: .string) }
		}
		pasteboard.clearContents()
		pasteboard.setString(text, forType: .string)
		try await body()
	}

	private func withClearedPasteboard(_ body: () async throws -> Void) async throws {
		let pasteboard = NSPasteboard.general
		let saved = pasteboard.string(forType: .string)
		defer {
			pasteboard.clearContents()
			if let saved { pasteboard.setString(saved, forType: .string) }
		}
		pasteboard.clearContents()
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
		harness.webView.window?.makeFirstResponder(harness.webView)
		harness.webView.perform(NSSelectorFromString("paste:"), with: nil)
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
			harness.webView.window?.makeFirstResponder(harness.webView)
			harness.webView.perform(NSSelectorFromString("paste:"))
			try await harness.waitForSourceEdits(1)
		}
		#expect(harness.source == "alpha X charlie\n")
		try await harness.waitQuiescent()
		#expect(try await harness.stampMismatches() == [])
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
		// The page freezes before posting, so a paste the host can't fulfil must
		// still thaw it — otherwise typing stays silently dead until the
		// frozen-timeout safety net fires seconds later.
		let pasteboard = NSPasteboard.general
		let saved = pasteboard.string(forType: .string)
		defer {
			pasteboard.clearContents()
			if let saved { pasteboard.setString(saved, forType: .string) }
		}
		pasteboard.clearContents()   // declares no types at all

		let harness = try await CoordinatorBridgeHarness(source: "alpha beta\n")
		try await harness.placeCaret(5)
		harness.webView.window?.makeFirstResponder(harness.webView)
		harness.webView.perform(NSSelectorFromString("paste:"), with: nil)
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
				harness.webView.window?.makeFirstResponder(harness.webView)
				harness.webView.perform(NSSelectorFromString("cut:"), with: nil)
				try await harness.waitForSourceEdits(1)
				let copied = NSPasteboard.general.string(forType: .string) ?? ""
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
			harness.webView.window?.makeFirstResponder(harness.webView)
			harness.webView.perform(NSSelectorFromString("cut:"), with: nil)
			try await harness.waitForSourceEdits(1)
			let copied = NSPasteboard.general.string(forType: .string) ?? ""
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
}
#endif
