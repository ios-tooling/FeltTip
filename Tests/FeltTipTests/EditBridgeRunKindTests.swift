//
//  EditBridgeRunKindTests.swift
//  FeltTipTests
//
//  Typing inside every kind of stamped run the renderer emits — headings,
//  quotes, link labels, code spans, emphasis — plus the geometry that trips
//  offset math: document edges, astral characters, and edits whose length
//  delta has to reach every later stamp. Each test also asserts the
//  stamp/source invariant, so a drift that happens to leave the *text* right
//  still fails.
//

import Testing
@testable import FeltTip

@Suite(.serialized) @MainActor struct EditBridgeRunKindTests {
	/// UTF-16 offset of `needle` in `haystack` — the coordinate system every
	/// data-s stamp and edit message uses.
	static func offset(of needle: String, in haystack: String) -> Int {
		(haystack as NSString).range(of: needle).location
	}

	@Test func typingInsideAHeading() async throws {
		let source = "# Title\n\nbody text\n"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.type("X", at: Self.offset(of: "itle", in: source))
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "# TXitle\n\nbody text\n")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
	}

	@Test func typingInsideABlockquote() async throws {
		let source = "> quoted line\n"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.type("X", at: Self.offset(of: "line", in: source))
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "> quoted Xline\n")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func typingInsideALinkLabelKeepsTheURL() async throws {
		let source = "see [the label](https://example.com) now\n"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.type("X", at: Self.offset(of: "label", in: source))
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "see [the Xlabel](https://example.com) now\n")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
	}

	@Test func replacingTheWholeRenderedLinkLabelKeepsTheURL() async throws {
		let source = "see [the label](https://example.com) now\n"
		let labelStart = Self.offset(of: "the label", in: source)
		let cases: [(String, [String])] = [
			("word navigation", [
				"window.__mdPlaceCaret(\(labelStart))",
				"window.getSelection().modify('extend', 'forward', 'word')",
				"window.getSelection().modify('extend', 'forward', 'word')",
			]),
			("text nodes", [
				"var link = document.querySelector('a[href]')",
				"var range = document.createRange()",
				"range.setStart(link.firstChild, 0)",
				"range.setEnd(link.firstChild, link.firstChild.nodeValue.length)",
				"var selection = window.getSelection()",
				"selection.removeAllRanges()",
				"selection.addRange(range)",
			]),
			("previous-run boundary", [
				"var link = document.querySelector('a[href]')",
				"var previous = link.closest('[data-s]').previousElementSibling.firstChild",
				"var range = document.createRange()",
				"range.setStart(previous, previous.nodeValue.length)",
				"range.setEnd(link.firstChild, link.firstChild.nodeValue.length)",
				"var selection = window.getSelection()",
				"selection.removeAllRanges()",
				"selection.addRange(range)",
			]),
			("next-run boundary", [
				"var link = document.querySelector('a[href]')",
				"var next = link.closest('[data-s]').nextElementSibling.nextElementSibling.firstChild",
				"var range = document.createRange()",
				"range.setStart(link.firstChild, 0)",
				"range.setEnd(next, 0)",
				"var selection = window.getSelection()",
				"selection.removeAllRanges()",
				"selection.addRange(range)",
			]),
			("both adjacent boundaries", [
				"var link = document.querySelector('a[href]')",
				"var previous = link.closest('[data-s]').previousElementSibling.firstChild",
				"var next = link.closest('[data-s]').nextElementSibling.nextElementSibling.firstChild",
				"var range = document.createRange()",
				"range.setStart(previous, previous.nodeValue.length)",
				"range.setEnd(next, 0)",
				"var selection = window.getSelection()",
				"selection.removeAllRanges()",
				"selection.addRange(range)",
			]),
		]
		for (name, commands) in cases {
			let harness = try await CoordinatorBridgeHarness(source: source)
			try await harness.batch(commands)
			try await harness.run("document.execCommand('insertText', false, 'new label')")
			try await harness.waitForSourceEdits(1)
			try await harness.waitQuiescent()

			#expect(harness.source == "see [new label](https://example.com) now\n", Comment(rawValue: name))
			#expect(try await harness.stampMismatches() == [], Comment(rawValue: name))
			#expect(harness.coordinator.hardRejections == 0, Comment(rawValue: name))
		}
	}

	@Test func typingInsideACodeSpan() async throws {
		let source = "call `printf` here\n"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.type("X", at: Self.offset(of: "rintf", in: source))
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "call `pXrintf` here\n")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func typingInsideEmphasisKeepsItsMarkers() async throws {
		let source = "an *italic* word\n"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.type("X", at: Self.offset(of: "talic", in: source))
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "an *iXtalic* word\n")
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func typingAtTheVeryStartOfTheDocument() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "alpha beta\n")
		try await harness.type("X", at: 0)
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "Xalpha beta\n")
		#expect(harness.lastCaretHint == 1)
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func typingAtTheEndOfTheLastRun() async throws {
		let source = "alpha beta\n"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.type("X", at: Self.offset(of: "\n", in: source))
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "alpha betaX\n")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
	}

	@Test func forwardDeleteRemovesTheFollowingCharacter() async throws {
		let source = "alpha beta\n"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.batch([
			"window.__mdPlaceCaret(\(Self.offset(of: "beta", in: source)))",
			"document.execCommand('forwardDelete')",
		])
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "alpha eta\n")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func astralCharacterShiftsLaterStampsByTwo() async throws {
		// An emoji is two UTF-16 units: the stamps after it must move by 2, not
		// 1, or the next edit in a later paragraph splices one char off.
		let source = "alpha\n\nbeta\n"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.type("😀", at: Self.offset(of: "lpha", in: source))
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "a😀lpha\n\nbeta\n")
		#expect(harness.lastCaretHint == 3)
		#expect(try await harness.stampMismatches() == [])

		try await harness.type("Z", at: Self.offset(of: "eta", in: harness.source))
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == "a😀lpha\n\nbZeta\n")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
	}

	@Test func typingBesideAnExistingEmoji() async throws {
		let source = "wave 👋 here\n"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.type("X", at: Self.offset(of: "here", in: source))
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "wave 👋 Xhere\n")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func typingAccentedTextSplicesVerbatim() async throws {
		let source = "cafe here\n"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.type("é", at: Self.offset(of: " here", in: source))
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "cafeé here\n")
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func deletingASelectionWithinOneRun() async throws {
		let source = "alpha bravo charlie\n"
		let harness = try await CoordinatorBridgeHarness(source: source)
		let start = Self.offset(of: "bravo", in: source)
		try await harness.batch([
			"window.__mdPlaceCaret(\(start))",
			"var s = window.getSelection(); var r = s.getRangeAt(0).cloneRange();"
				+ "r.setEnd(r.startContainer, r.startOffset + 6); s.removeAllRanges(); s.addRange(r)",
			"document.execCommand('delete')",
		])
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "alpha charlie\n")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func cuttingASelectedInlineCodeRun() async throws {
		let source = "- `TimelineEntryWidget` that extends `LeafRenderObjectWidget`\n"
		let harness = try await CoordinatorBridgeHarness(source: source)
		let start = Self.offset(of: "TimelineEntryWidget", in: source)
		try await harness.batch([
			"window.__mdPlaceCaret(\(start), 19)",
			"var cut = new InputEvent('beforeinput', { inputType: 'deleteByCut', bubbles: true, cancelable: true })",
			"document.body.dispatchEvent(cut)",
			"if (!cut.defaultPrevented) { window.getSelection().deleteFromDocument();"
				+ "document.body.dispatchEvent(new InputEvent('input', { inputType: 'deleteByCut', bubbles: true })) }",
		])
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "-  that extends `LeafRenderObjectWidget`\n")
		try await harness.waitQuiescent()
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func asCodeTogglesASelectionOnAndOff() async throws {
		let source = "- TimelineEntryWidget that extends LeafRenderObjectWidget\n"
		let harness = try await CoordinatorBridgeHarness(source: source)
		let start = Self.offset(of: "TimelineEntryWidget", in: source)
		try await harness.batch([
			"window.__mdPlaceCaret(\(start), 19)",
			"window.__mdToggleInlineCode()",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		#expect(harness.source == "- `TimelineEntryWidget` that extends LeafRenderObjectWidget\n")
		#expect(try await harness.evaluate("window.getSelection().toString()") == "TimelineEntryWidget")
		#expect(try await harness.stampMismatches() == [])

		try await harness.run("window.__mdToggleInlineCode()")
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()
		#expect(harness.source == source)
		#expect(try await harness.evaluate("window.getSelection().toString()") == "TimelineEntryWidget")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func selectAllThenTypeLeavesPageAndSourceAgreeing() async throws {
		// A whole-document replacement is the most violent edit the bridge can
		// see. Whatever it decides (splice or resync), the page must end up
		// describing the source it actually has.
		let harness = try await CoordinatorBridgeHarness(source: "# Head\n\nalpha *beta*\n\n- one\n- two\n")
		try await harness.batch([
			"document.execCommand('selectAll')",
			"document.execCommand('insertText', false, 'Z')",
		])
		try await Task.sleep(for: .milliseconds(400))
		try await harness.waitQuiescent()
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.hardRejections == 0)
		#expect(harness.coordinator.bridgeIncidents == [])
	}

	@Test func editsInEveryBlockOfAMixedDocumentAllLand() async throws {
		let source = "# Head\n\npara one\n\n> quote\n\n- item\n\n| a | b |\n| --- | --- |\n| c | d |\n"
		let harness = try await CoordinatorBridgeHarness(source: source)
		var expected = source
		var edits = 0
		for anchor in ["Head", "para", "quote", "item", "c"] {
			let at = Self.offset(of: anchor, in: harness.source)
			try await harness.type("X", at: at)
			edits += 1
			try await harness.waitForSourceEdits(edits)
			expected = (expected as NSString).replacingCharacters(
				in: NSRange(location: (expected as NSString).range(of: anchor).location, length: 0), with: "X")
			#expect(harness.source == expected, "editing \(anchor)")
			#expect(try await harness.stampMismatches() == [], "stamps after editing \(anchor)")
		}
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}
}
