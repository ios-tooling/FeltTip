//
//  EditBridgeBoundaryTests.swift
//  MarkDownRangeTests
//
//  Structural edits at document/list boundaries, style toggles at run edges,
//  the collapsed cross-run delete veto, and unmappable (unstamped) runs.
//

import Testing
@testable import MarkDownRange

@Suite(.serialized) @MainActor struct EditBridgeBoundaryTests {
	@Test func enterAtDocumentStartAndEnd() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha\n\nBeta")
		try await harness.batch(["window.__mdPlaceCaret(0)", "document.execCommand('insertParagraph')"])
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "\n\nAlpha\n\nBeta")
		try await harness.waitQuiescent()
		let end = (harness.source as NSString).length
		try await harness.batch(["window.__mdPlaceCaret(\(end))", "document.execCommand('insertParagraph')"])
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == "\n\nAlpha\n\nBeta\n\n")
		#expect(harness.coordinator.resyncCount == 0)
	}

	@Test(arguments: [
		("**Bold**", "**Bold**\n\nX"),
		("_Italic_", "_Italic_\n\nX"),
		("[Link](https://example.com)", "[Link](https://example.com)\n\nX"),
		("***Bold Italic***", "***Bold Italic***\n\nX"),
		("[**Bold Link**](https://example.com)", "[**Bold Link**](https://example.com)\n\nX"),
		("~~**Bold Strike**~~", "~~**Bold Strike**~~\n\nX"),
	])
	func returnAfterCollapsingSelectAllToTheRightExitsTerminalInlineSyntax(
		source: String,
		expected: String
	) async throws {
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.batch([
			"document.execCommand('selectAll')",
			"window.getSelection().collapseToEnd()",
			"document.execCommand('insertParagraph')",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		try await harness.type("X", at: (harness.source as NSString).length)
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == expected)
		#expect(harness.coordinator.hardRejections == 0)
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func returnAtAnInternalPlainBlockStartRestampsTheMovedBlock() async throws {
		let source = "Alpha paragraph\n\nBeta paragraph **tail**"
		let harness = try await CoordinatorBridgeHarness(source: source)
		let caret = (source as NSString).range(of: "Beta").location
		try await harness.batch([
			"window.__mdPlaceCaret(\(caret))",
			"document.execCommand('insertParagraph')",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		#expect(harness.source == "Alpha paragraph\n\n\n\nBeta paragraph **tail**")
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func insertingBetweenLiteralDelimitersRefreshesTheirMarkdownMeaning() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "b**")
		try await harness.type("a", at: 2)
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		#expect(harness.source == "b*a*")
		#expect(Self.compactVisible(try await harness.domVisibleText()) == "ba")
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func whitespaceAtAnEmphasisBoundaryRefreshesInvalidatedSyntax() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "*a*")
		try await harness.type(" ", at: 1)
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		#expect(harness.source == "* a*")
		let visible = Self.compactVisible(try await harness.domVisibleText())
		#expect(visible == "a*", "\(visible.debugDescription)")
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func deletingTheOnlyEmphasizedCharacterRefreshesLiteralDelimiters() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "*a*")
		try await harness.batch([
			"window.__mdPlaceCaret(2)",
			"document.execCommand('delete')",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		#expect(harness.source == "**")
		let visible = Self.compactVisible(try await harness.domVisibleText())
		#expect(visible == "**", "\(visible.debugDescription)")
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func deletingFirstStyledCharacterThatRevealsWhitespaceRefreshesSyntax() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "m**é a 3**")
		try await harness.batch([
			"window.__mdPlaceCaret(4)",
			"document.execCommand('delete')",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		#expect(harness.source == "m** a 3**")
		let visible = Self.compactVisible(try await harness.domVisibleText())
		#expect(visible == "m** a 3**", "\(visible.debugDescription)")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func typingBesideStyledRunRefreshesDistantDelimiterPairing() async throws {
		let source = "text t**ext **delta gamma **beta**"
		let harness = try await CoordinatorBridgeHarness(source: source)
		let caret = (source as NSString).range(of: "beta").location
		try await harness.type("z", at: caret)
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		#expect(harness.source == "text t**ext **delta gamma z**beta**")
		let live = Self.compactVisible(try await harness.domVisibleText())
		let fresh = try await CoordinatorBridgeHarness(source: harness.source)
		let rendered = Self.compactVisible(try await fresh.domVisibleText())
		#expect(live == rendered, "live \(live.debugDescription), rendered \(rendered.debugDescription)")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func punctuationAtStyledRunEndRefreshesDelimiterPairing() async throws {
		let source = "**alpha**s ample**"
		let harness = try await CoordinatorBridgeHarness(source: source)
		let alpha = (source as NSString).range(of: "alpha")
		try await harness.type("\"", at: alpha.location + alpha.length)
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		#expect(harness.source == "**alpha\"**s ample**")
		let live = Self.compactVisible(try await harness.domVisibleText())
		let fresh = try await CoordinatorBridgeHarness(source: harness.source)
		let rendered = Self.compactVisible(try await fresh.domVisibleText())
		#expect(live == rendered, "live \(live.debugDescription), rendered \(rendered.debugDescription)")
		#expect(try await harness.stampMismatches() == [])
	}

	private static func compactVisible(_ text: String) -> String {
		text.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	@Test func enterInListItemContinuesTheList() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "- one\n- two")
		try await harness.batch(["window.__mdPlaceCaret(5)", "document.execCommand('insertParagraph')"])
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "- one\n- \n- two")
		#expect(harness.coordinator.resyncCount == 0)
	}

	@Test func backspaceAfterEnterAtSoftWrapBoundaryPreservesTheSpace() async throws {
		let source = "Alpha Beta\n\nTail"
		let harness = try await CoordinatorBridgeHarness(source: source)
		// Force the first paragraph to wrap at its existing space, matching the
		// user route: the caret sits before "Beta" at the start of a visual line.
		try await harness.run("document.querySelector('p').style.width = '60px'")
		try await harness.batch([
			"window.__mdPlaceCaret(6)",
			"document.execCommand('insertParagraph')",
		])
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "Alpha \n\nBeta\n\nTail")

		try await harness.waitQuiescent()
		try await harness.run("document.execCommand('delete')")
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == source)
		try await harness.waitQuiescent()
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
		let mismatches = try await harness.stampMismatches()
		#expect(mismatches.isEmpty, "stamp mismatches: \(mismatches)")
	}

	@Test func boldToggleAtRunBoundaryKeepsNeighbors() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "plain **bold** tail")
		// Select "plain" (offsets 0-5) and bold it; the existing bold run
		// after it must be untouched.
		try await harness.batch([
			"window.__mdPlaceCaret(5)",
			"var sel = window.getSelection()",
			"for (var i = 0; i < 5; i++) sel.modify('extend', 'backward', 'character')",
			"document.execCommand('bold')",
		])
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "**plain** **bold** tail")
		#expect(harness.coordinator.resyncCount == 0)
	}

	@Test func collapsedCrossRunBackspaceIsVetoedOrSafe() async throws {
		// Backspace at the start of "tail" — the range crosses into the bold
		// run's hidden `**`. A collapsed merge must never silently eat syntax.
		let harness = try await CoordinatorBridgeHarness(source: "**bold** tail")
		try await harness.batch([
			"window.__mdPlaceCaret(9)",
			"document.execCommand('delete')",
		])
		try await Task.sleep(for: .milliseconds(300))
		// Whatever the path (veto, splice of the space, or resync), the bold
		// syntax must survive in the source.
		#expect(harness.source.contains("**bold**"), "hidden syntax was eaten: \(harness.source)")
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func backspaceAtBoldParagraphStartPreservesOpeningSyntax() async throws {
		let source = "Print the stored authentication token\n\n\n**Examples:**\n\nCommand"
		let harness = try await CoordinatorBridgeHarness(source: source)
		let caret = (source as NSString).range(of: "Examples:").location
		try await harness.batch([
			"window.__mdPlaceCaret(\(caret))",
			"document.execCommand('delete')",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		#expect(harness.source == "Print the stored authentication token**Examples:**\n\nCommand")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func caretInUnstampedRunVetoesTypingWithoutCorruption() async throws {
		// An entity reference renders as a run the converter can't map 1:1, so
		// it carries no data-s stamp; typing inside it must do nothing (veto)
		// rather than corrupt neighboring source.
		let harness = try await CoordinatorBridgeHarness(source: "a &amp; b\n\nBeta")
		try await harness.run("""
			var spans = document.querySelectorAll('p, li');
			var sel = window.getSelection(), r = document.createRange();
			var amp = null;
			var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
			var n; while ((n = walker.nextNode())) { if (n.nodeValue.indexOf('&') !== -1) { amp = n; break; } }
			if (amp) { r.setStart(amp, 1); r.collapse(true); sel.removeAllRanges(); sel.addRange(r); }
			document.execCommand('insertText', false, 'X')
			""")
		try await Task.sleep(for: .milliseconds(300))
		#expect(harness.source == "a &amp; b\n\nBeta", "typing in an unmappable run must not alter the source")
		#expect(harness.coordinator.hardRejections == 0)
	}
}
