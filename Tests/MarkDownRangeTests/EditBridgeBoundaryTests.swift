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

	@Test func typingAfterDelimiterDeletionKeepsNestedRunStampsAligned() async throws {
		let source = "am****ma d**e**lta **ba\n\ny\n\ny\n\ny"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.batch([
			"window.__mdPlaceCaret(5)",
			"document.execCommand('delete')",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		#expect(harness.source == "am***ma d**e**lta **ba\n\ny\n\ny\n\ny")

		try await harness.type("\u{00A0}", at: 6)
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()
		#expect(harness.source == "am***m a d**e**lta **ba\n\ny\n\ny\n\ny")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
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

	@Test func wordDeletionThatActivatesAClosingHeadingMarkerRerenders() async throws {
		let source = "#  Bet# \n\nTail"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.run("""
			window.__mdPlaceCaret(3, 3)
			var target = window.getSelection().getRangeAt(0).cloneRange()
			window.getSelection().collapseToStart()
			var deletion = new InputEvent('beforeinput', {
			  inputType: 'deleteWordForward', bubbles: true, cancelable: true
			})
			Object.defineProperty(deletion, 'getTargetRanges', {
			  value: function () { return [target] }
			})
			var allowed = document.body.dispatchEvent(deletion)
			if (allowed) {
			  target.deleteContents()
			  document.body.dispatchEvent(new InputEvent('input', {
			    inputType: 'deleteWordForward', bubbles: true
			  }))
			}
			""")
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		#expect(harness.source == "#  # \n\nTail")
		let visible = EditBridgeFuzzTests.normalizedVisibleText(
			try await harness.domVisibleText())
		#expect(visible == "Tail")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func deletionThatActivatesHighlightDelimitersRerenders() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "==Bet= x=\n\nTail")
		try await harness.run("""
			window.__mdPlaceCaret(6, 2)
			var target = window.getSelection().getRangeAt(0).cloneRange()
			window.getSelection().collapseToStart()
			var deletion = new InputEvent('beforeinput', {
			  inputType: 'deleteWordForward', bubbles: true, cancelable: true
			})
			Object.defineProperty(deletion, 'getTargetRanges', {
			  value: function () { return [target] }
			})
			var allowed = document.body.dispatchEvent(deletion)
			if (allowed) {
			  target.deleteContents()
			  document.body.dispatchEvent(new InputEvent('input', {
			    inputType: 'deleteWordForward', bubbles: true
			  }))
			}
			""")
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		#expect(harness.source == "==Bet==\n\nTail")
		let visible = EditBridgeFuzzTests.normalizedVisibleText(
			try await harness.domVisibleText())
		#expect(visible == "Bet\nTail")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func deletionThatActivatesInsertedTextDelimitersRerenders() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "++Bet+ x+\n\nTail")
		try await harness.run("""
			window.__mdPlaceCaret(6, 2)
			var target = window.getSelection().getRangeAt(0).cloneRange()
			window.getSelection().collapseToStart()
			var deletion = new InputEvent('beforeinput', {
			  inputType: 'deleteWordForward', bubbles: true, cancelable: true
			})
			Object.defineProperty(deletion, 'getTargetRanges', {
			  value: function () { return [target] }
			})
			var allowed = document.body.dispatchEvent(deletion)
			if (allowed) {
			  target.deleteContents()
			  document.body.dispatchEvent(new InputEvent('input', {
			    inputType: 'deleteWordForward', bubbles: true
			  }))
			}
			""")
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		#expect(harness.source == "++Bet++\n\nTail")
		let visible = EditBridgeFuzzTests.normalizedVisibleText(
			try await harness.domVisibleText())
		#expect(visible == "Bet\nTail")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func deletionThatActivatesSuperscriptDelimitersRerenders() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "^ Bet^\n\nTail")
		try await harness.run("""
			window.__mdPlaceCaret(1, 1)
			var target = window.getSelection().getRangeAt(0).cloneRange()
			window.getSelection().collapseToStart()
			var deletion = new InputEvent('beforeinput', {
			  inputType: 'deleteWordForward', bubbles: true, cancelable: true
			})
			Object.defineProperty(deletion, 'getTargetRanges', {
			  value: function () { return [target] }
			})
			var allowed = document.body.dispatchEvent(deletion)
			if (allowed) {
			  target.deleteContents()
			  document.body.dispatchEvent(new InputEvent('input', {
			    inputType: 'deleteWordForward', bubbles: true
			  }))
			}
			""")
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		#expect(harness.source == "^Bet^\n\nTail")
		let visible = EditBridgeFuzzTests.normalizedVisibleText(
			try await harness.domVisibleText())
		#expect(visible == "Bet\nTail")
		#expect(try await harness.evaluate(
			"document.querySelector('sup') ? 'yes' : 'no'") == "yes")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(try await harness.stampMismatches() == [])
	}

	@Test(arguments: [
		(source: "Term\nx: Definition\n\nTail", expected: "Term\n: Definition\n\nTail"),
		(source: "Term\n  x: Definition\n\nTail", expected: "Term\n  : Definition\n\nTail"),
		(source: "A reasonably long term\nx: Definition\n\nTail", expected: "A reasonably long term\n: Definition\n\nTail"),
		(source: "Term\nx- Item\n\nTail", expected: "Term\n- Item\n\nTail"),
		(source: "Term\nx1. Item\n\nTail", expected: "Term\n1. Item\n\nTail"),
		(source: "Term\nx> Quote\n\nTail", expected: "Term\n> Quote\n\nTail"),
	])
	func deletionThatActivatesBlockSyntaxAfterASoftLineRerenders(
		source: String,
		expected: String
	) async throws {
		let harness = try await CoordinatorBridgeHarness(source: source)
		let deletionOffset = (source as NSString).range(of: "x").location
		try await harness.run("""
			window.__mdPlaceCaret(\(deletionOffset), 1)
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

		#expect(harness.source == expected)
		let fresh = try await CoordinatorBridgeHarness(source: harness.source)
		let liveVisible = EditBridgeFuzzTests.normalizedVisibleText(
			try await harness.domVisibleText())
		let freshVisible = EditBridgeFuzzTests.normalizedVisibleText(
			try await fresh.domVisibleText())
		#expect(liveVisible == freshVisible,
			"live \(liveVisible.debugDescription), fresh \(freshVisible.debugDescription)")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(try await harness.stampMismatches() == [])

		let editsBeforeRestore = harness.sourceEditCount
		try await harness.type("x")
		try await harness.waitForSourceEdits(editsBeforeRestore + 1)
		try await harness.waitQuiescent()
		let restored = try await CoordinatorBridgeHarness(source: harness.source)
		let restoredLive = EditBridgeFuzzTests.normalizedVisibleText(
			try await harness.domVisibleText())
		let restoredFresh = EditBridgeFuzzTests.normalizedVisibleText(
			try await restored.domVisibleText())
		#expect(restoredLive == restoredFresh)
		#expect(try await harness.stampMismatches() == [])
	}

	@Test(arguments: [
		(command: "delete", expected: "Term\n : Definition\n\nTail"),
		(command: "forwardDelete", expected: "Term\n   Definition\n\nTail"),
		(command: "insertParagraph", expected: "Term\n  \n\n: Definition\n\nTail"),
		(command: "insertLineBreak", expected: "Term\n  " + "\\\n" + ": Definition\n\nTail"),
		(command: "bold", expected: "Term\n  ****: Definition\n\nTail"),
		(command: "italic", expected: "Term\n  **: Definition\n\nTail"),
		(command: "strikeThrough", expected: "Term\n  ~~~~: Definition\n\nTail"),
	])
	func deletionAfterAnIndentedSoftLineRestoreUsesTheSourceCaret(
		command: String,
		expected: String
	) async throws {
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

		try await harness.run("document.execCommand('\(command)')")
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()

		#expect(harness.source == expected)
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

	@Test func rapidTypingAfterAnIndentedSoftLineRestoreQueuesAtTheExactSourceCaret() async throws {
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

		try await harness.batch([
			"document.execCommand('insertText', false, 'X')",
			"document.execCommand('insertText', false, 'Y')",
		])
		try await harness.waitForSourceEdits(3)
		try await harness.waitQuiescent()

		#expect(harness.source == "Term\n  XY: Definition\n\nTail")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test(arguments: [
		(command: "underline", formatted: "<u>X</u>"),
		(command: "inlineCode", formatted: "`X`"),
		(command: "highlight", formatted: "==X=="),
		(command: "superscript", formatted: "^X^"),
		(command: "subscript", formatted: "~X~"),
		(command: "link", formatted: "[X]()"),
	])
	func customFormattingAfterAnIndentedSoftLineRestoreKeepsATypableSourceCaret(
		command: String,
		formatted: String
	) async throws {
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

		try await harness.run("window.__mdApplyFormat('\(command)')")
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()
		try await harness.type("X")
		try await harness.waitForSourceEdits(3)
		try await harness.waitQuiescent()

		#expect(harness.source == "Term\n  \(formatted): Definition\n\nTail")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test(arguments: [
		(command: "delete", expected: "Term\n <u>X</u>: Definition\n\nTail"),
		(command: "forwardDelete", expected: "Term\n  <u>X</u> Definition\n\nTail"),
	])
	func deletionFromAnEmptyUnderlineCaretTargetsVisibleTextAndKeepsTheCaretTypable(
		command: String,
		expected: String
	) async throws {
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
		try await harness.run("window.__mdApplyFormat('underline')")
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()

		try await harness.run("document.execCommand('\(command)')")
		try await harness.waitForSourceEdits(3)
		try await harness.waitQuiescent()
		try await harness.type("X")
		try await harness.waitForSourceEdits(4)
		try await harness.waitQuiescent()

		#expect(harness.source == expected)
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func emptyUnderlineCaretStaysBeforeFollowingUnstampedWhitespace() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha Tail")
		try await harness.batch([
			"window.__mdPlaceCaret(5)",
			"window.__mdApplyFormat('underline')",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		let adjacency = try await harness.evaluate("""
			var home = document.querySelector('[data-md-inline-caret-source-neutral]')
			home && home.nextSibling
			  ? String(home.nextSibling.textContent.charCodeAt(0))
			  : 'missing'
			""")
		#expect(adjacency == "32", "caret adjacency was \(adjacency.debugDescription)")
		try await harness.type("X")
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()

		#expect(harness.source == "Alpha<u>X</u> Tail")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test(arguments: [
		(command: "delete", expected: "<u>X</u> Tail"),
		(command: "forwardDelete", expected: "🙂<u>X</u>Tail"),
	])
	func deletionFromAnEmptyUnderlineCaretKeepsComposedCharacterOffsetsExact(
		command: String,
		expected: String
	) async throws {
		let harness = try await CoordinatorBridgeHarness(source: "🙂 Tail")
		try await harness.batch([
			"window.__mdPlaceCaret(2)",
			"window.__mdApplyFormat('underline')",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		try await harness.run("document.execCommand('\(command)')")
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()
		try await harness.type("X")
		try await harness.waitForSourceEdits(3)
		try await harness.waitQuiescent()

		#expect(harness.source == expected)
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test(arguments: [
		(command: "deleteWordBackward", source: "alpha Tail", caret: 5,
		 expected: "<u>X</u> Tail"),
		(command: "deleteWordForward", source: "Alpha bravo Tail", caret: 5,
		 expected: "Alpha<u>X</u> Tail"),
		(command: "deleteWordForward", source: "Alpha bravo", caret: 5,
		 expected: "Alpha<u>X</u>"),
	])
	func wordDeletionFromAnEmptyUnderlineCaretUsesTheAdjacentVisibleWord(
		command: String,
		source: String,
		caret: Int,
		expected: String
	) async throws {
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.batch([
			"window.__mdPlaceCaret(\(caret))",
			"window.__mdApplyFormat('underline')",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		try await harness.run("""
			document.body.dispatchEvent(new InputEvent('beforeinput', {
			  inputType: '\(command)', bubbles: true, cancelable: true
			}))
			""")
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()
		try await harness.type("X")
		try await harness.waitForSourceEdits(3)
		try await harness.waitQuiescent()

		#expect(harness.source == expected)
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test(arguments: [
		(command: "deleteWordBackward", source: "Tail", caret: 0,
		 expected: "<u>X</u>Tail"),
		(command: "deleteWordForward", source: "Alpha", caret: 5,
		 expected: "Alpha<u>X</u>"),
	])
	func wordDeletionWithoutAnAdjacentWordLeavesTheEmptyCaretLive(
		command: String,
		source: String,
		caret: Int,
		expected: String
	) async throws {
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.batch([
			"window.__mdPlaceCaret(\(caret))",
			"window.__mdApplyFormat('underline')",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		try await harness.run("""
			document.body.dispatchEvent(new InputEvent('beforeinput', {
			  inputType: '\(command)', bubbles: true, cancelable: true
			}))
			""")
		try await harness.waitQuiescent()
		#expect(harness.sourceEditCount == 1)
		#expect(try await harness.evaluate("window.__mdIsFrozen() ? 'yes' : 'no'") == "no")
		try await harness.type("X")
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()

		#expect(harness.source == expected)
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test(arguments: [
		(command: "delete", expected: "Alph<u></u> Tail"),
		(command: "forwardDelete", expected: "Alpha<u></u>Tail"),
		(command: "deleteWordBackward", expected: "<u></u> Tail"),
		(command: "deleteWordForward", expected: "Alpha<u></u>"),
	])
	func deletionAfterAHostRestoredEmptyUnderlineTargetsVisibleText(
		command: String,
		expected: String
	) async throws {
		let formatted = "Alpha<u></u> Tail"
		let harness = try await CoordinatorBridgeHarness(source: "Seed")
		harness.focusWebView()
		harness.coordinator.parent = MarkdownWebView(
			text: formatted, theme: .default, fontSize: 15)
			.editable(true)
			.caretTarget(MarkdownCaretTarget(offset: 12, token: 703))
			.onSourceEdit { [weak harness] newText, _ in
				harness?.recordExternalEdit(newText)
			}
		harness.coordinator.applyCaretTarget()
		harness.coordinator.load(into: harness.webView)
		harness.adoptHostText(formatted)
		try await harness.waitUntil("full-navigation post-wrapper caret") {
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
		if command.contains("Word") {
			try await harness.run("""
				document.body.dispatchEvent(new InputEvent('beforeinput', {
				  inputType: '\(command)', bubbles: true, cancelable: true
				}))
				""")
		} else {
			try await harness.run("document.execCommand('\(command)')")
		}
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		#expect(harness.source == expected, "command=\(command)")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test(arguments: [
		(command: "forwardDelete", caret: 4, expected: "A<u></u><u></u>",
		 afterTyping: "A<u>X</u><u></u>"),
		(command: "deleteWordForward", caret: 4, expected: "A<u></u><u></u>",
		 afterTyping: "A<u>X</u><u></u>"),
		(command: "forwardDelete", caret: 8, expected: "A<u></u><u></u>",
		 afterTyping: "A<u></u>X<u></u>"),
		(command: "deleteWordForward", caret: 8, expected: "A<u></u><u></u>",
		 afterTyping: "A<u></u>X<u></u>"),
		(command: "delete", caret: 11, expected: "<u></u><u></u>B",
		 afterTyping: "<u></u><u>X</u>B"),
		(command: "deleteWordBackward", caret: 11, expected: "<u></u><u></u>B",
		 afterTyping: "<u></u><u>X</u>B"),
		(command: "delete", caret: 15, expected: "<u></u><u></u>B",
		 afterTyping: "<u></u><u></u>XB"),
		(command: "deleteWordBackward", caret: 15, expected: "<u></u><u></u>B",
		 afterTyping: "<u></u><u></u>XB"),
	])
	func deletionBesideAdjacentRestoredEmptyUnderlinesSkipsAllHiddenWrappers(
		command: String,
		caret: Int,
		expected: String,
		afterTyping: String
	) async throws {
		let source = "A<u></u><u></u>B"
		let harness = try await CoordinatorBridgeHarness(source: "Seed")
		harness.focusWebView()
		harness.coordinator.parent = MarkdownWebView(
			text: source, theme: .default, fontSize: 15)
			.editable(true)
			.caretTarget(MarkdownCaretTarget(offset: caret, token: 710))
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
				""") == String(caret)
		}
		harness.rewireRoundTrip()
		if command.contains("Word") {
			try await harness.run("""
				document.body.dispatchEvent(new InputEvent('beforeinput', {
				  inputType: '\(command)', bubbles: true, cancelable: true
				}))
				""")
		} else {
			try await harness.run("document.execCommand('\(command)')")
		}
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		#expect(harness.source == expected, "command=\(command), caret=\(caret)")
		try await harness.type("X")
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()
		#expect(harness.source == afterTyping, "command=\(command), caret=\(caret)")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test(arguments: [
		(command: "forwardDelete", caret: 15,
		 expected: "A<U></U><u></u><U></U>"),
		(command: "deleteWordForward", caret: 15,
		 expected: "A<U></U><u></u><U></U>"),
		(command: "delete", caret: 22,
		 expected: "<U></U><u></u><U></U>B"),
		(command: "deleteWordBackward", caret: 22,
		 expected: "<U></U><u></u><U></U>B"),
	])
	func deletionBesideThreeCaseVaryingEmptyUnderlinesSkipsTheWholeCluster(
		command: String,
		caret: Int,
		expected: String
	) async throws {
		let source = "A<U></U><u></u><U></U>B"
		let harness = try await CoordinatorBridgeHarness(source: "Seed")
		harness.focusWebView()
		harness.coordinator.parent = MarkdownWebView(
			text: source, theme: .default, fontSize: 15)
			.editable(true)
			.caretTarget(MarkdownCaretTarget(offset: caret, token: 713))
			.onSourceEdit { [weak harness] newText, _ in
				harness?.recordExternalEdit(newText)
			}
		harness.coordinator.applyCaretTarget()
		harness.coordinator.load(into: harness.webView)
		harness.adoptHostText(source)
		try await harness.waitUntil("case-varying empty-wrapper caret") {
			try await harness.evaluate("""
				(function () {
				  var home = document.querySelector('[data-md-inline-caret-home]')
				  return home ? home.getAttribute('data-md-inline-caret-offset') : 'missing'
				})()
				""") == String(caret)
		}
		harness.rewireRoundTrip()
		if command.contains("Word") {
			try await harness.run("""
				document.body.dispatchEvent(new InputEvent('beforeinput', {
				  inputType: '\(command)', bubbles: true, cancelable: true
				}))
				""")
		} else {
			try await harness.run("document.execCommand('\(command)')")
		}
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		#expect(harness.source == expected, "command=\(command), caret=\(caret)")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test(arguments: [
		(command: "delete", caret: 6,
		 expected: "A `<u</u>` B", afterTyping: "A `<uX</u>` B"),
		(command: "forwardDelete", caret: 6,
		 expected: "A `<u>/u>` B", afterTyping: "A `<u>X/u>` B"),
		(command: "delete", caret: 10,
		 expected: "A `<u></u` B", afterTyping: "A `<u></uX` B"),
	])
	func deletionBesideAVisibleEmptyUnderlineLiteralInCodeTargetsVisibleCharacters(
		command: String,
		caret: Int,
		expected: String,
		afterTyping: String
	) async throws {
		let source = "A `<u></u>` B"
		let harness = try await CoordinatorBridgeHarness(source: "Seed")
		harness.focusWebView()
		harness.coordinator.parent = MarkdownWebView(
			text: source, theme: .default, fontSize: 15)
			.editable(true)
			.caretTarget(MarkdownCaretTarget(offset: caret, token: 714))
			.onSourceEdit { [weak harness] newText, _ in
				harness?.recordExternalEdit(newText)
			}
		harness.coordinator.applyCaretTarget()
		harness.coordinator.load(into: harness.webView)
		harness.adoptHostText(source)
		try await harness.waitUntil("inline-code caret") {
			try await harness.evaluate("""
				(function () {
				  var selection = window.getSelection()
				  return selection && selection.anchorNode
				    ? selection.anchorNode.parentElement.tagName : 'missing'
				})()
				""") == "CODE"
		}
		harness.rewireRoundTrip()
		try await harness.run("document.execCommand('\(command)')")
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		#expect(harness.source == expected, "command=\(command), caret=\(caret)")
		try await harness.type("X")
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()

		#expect(harness.source == afterTyping, "command=\(command), caret=\(caret)")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func backspaceAfterAnEscapedEmptyUnderlineLiteralTargetsItsVisibleText() async throws {
		let source = "A \\<u></u> B"
		let harness = try await CoordinatorBridgeHarness(source: "Seed")
		harness.focusWebView()
		harness.coordinator.parent = MarkdownWebView(
			text: source, theme: .default, fontSize: 15)
			.editable(true)
			.caretTarget(MarkdownCaretTarget(offset: 10, token: 715))
			.onSourceEdit { [weak harness] newText, _ in
				harness?.recordExternalEdit(newText)
			}
		harness.coordinator.applyCaretTarget()
		harness.coordinator.load(into: harness.webView)
		harness.adoptHostText(source)
		try await harness.waitUntil("escaped literal caret") {
			try await harness.evaluate("""
				(function () {
				  var selection = window.getSelection()
				  if (!selection || !selection.anchorNode) return 'missing'
				  return document.querySelector(
				    '[data-md-inline-caret-source-neutral], ' +
				    '[data-md-inline-caret-after-empty-wrapper]') ? 'empty-wrapper' : 'ordinary'
				})()
				""") == "ordinary"
		}
		harness.rewireRoundTrip()
		try await harness.run("document.execCommand('delete')")
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		#expect(harness.source == "A \\<u></u B")
		try await harness.type("X")
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()

		#expect(harness.source == "A \\<u></uX B")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func backspaceAfterAnEmptyUnderlineWithAnEscapedBackslashDeletesTheVisibleSlash() async throws {
		let source = #"A \\<u></u> B"#
		let harness = try await CoordinatorBridgeHarness(source: "Seed")
		harness.focusWebView()
		harness.coordinator.parent = MarkdownWebView(
			text: source, theme: .default, fontSize: 15)
			.editable(true)
			.caretTarget(MarkdownCaretTarget(offset: 11, token: 716))
			.onSourceEdit { [weak harness] newText, _ in
				harness?.recordExternalEdit(newText)
			}
		harness.coordinator.applyCaretTarget()
		harness.coordinator.load(into: harness.webView)
		harness.adoptHostText(source)
		try await harness.waitUntil("post-wrapper escaped-backslash caret") {
			try await harness.evaluate("""
				(function () {
				  var home = document.querySelector(
				    '[data-md-inline-caret-after-empty-wrapper]')
				  return home ? home.getAttribute('data-md-inline-caret-offset') : 'missing'
				})()
				""") == "11"
		}
		harness.rewireRoundTrip()
		try await harness.run("document.execCommand('delete')")
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		#expect(harness.source == "A <u></u> B")
		try await harness.type("X")
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()

		#expect(harness.source == "A <u></u>X B")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test(arguments: [
		(source: "[Link](https://example.com/<u></u>) Tail",
		 expected: "[Link](https://example.com/<u></u>)X Tail"),
		(source: "[Link](https://example.com/a(b)/<u></u>) Tail",
		 expected: "[Link](https://example.com/a(b)/<u></u>)X Tail"),
		(source: "[Link](https://example.com/a\\)/<u></u>) Tail",
		 expected: "[Link](https://example.com/a\\)/<u></u>)X Tail"),
	])
	func aWrapperSpellingInsideALinkDestinationUsesHiddenSyntaxCaretSnapping(
		source: String,
		expected: String
	) async throws {
		let caret = (source as NSString).range(of: "<u></u>").upperBound
		let harness = try await CoordinatorBridgeHarness(source: "Seed")
		harness.focusWebView()
		harness.coordinator.parent = MarkdownWebView(
			text: source, theme: .default, fontSize: 15)
			.editable(true)
			.caretTarget(MarkdownCaretTarget(offset: caret, token: 718))
			.onSourceEdit { [weak harness] newText, _ in
				harness?.recordExternalEdit(newText)
			}
		harness.coordinator.applyCaretTarget()
		harness.coordinator.load(into: harness.webView)
		harness.adoptHostText(source)
		try await harness.waitQuiescent()
		#expect(try await harness.evaluate("""
			document.querySelector('[data-md-inline-caret-after-empty-wrapper]')
			  ? 'empty-wrapper' : 'hidden-syntax'
			""") == "hidden-syntax")
		harness.rewireRoundTrip()
		try await harness.type("X")
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		#expect(harness.source == expected)
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test(arguments: [
		(direction: "backward", expected: "AlphXa<u></u> Tail"),
		(direction: "forward", expected: "Alpha<u></u> XTail"),
	])
	func arrowingAwayFromAnEmptyUnderlineCaretMovesByAVisibleCharacter(
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
			  key: '\(key)', bubbles: true, cancelable: true
			})
			if (document.body.dispatchEvent(arrow)) {
			  window.getSelection().modify('move', '\(direction)', 'character')
			}
			""")
		try await harness.type("X")
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()

		#expect(harness.source == expected, "direction=\(direction)")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test(arguments: [
		(direction: "backward", expected: "AlphXa<u></u> Tail"),
		(direction: "forward", expected: "Alpha<u></u> XTail"),
	])
	func arrowingAwayFromAHostRestoredPostWrapperCaretMovesByAVisibleCharacter(
		direction: String,
		expected: String
	) async throws {
		let formatted = "Alpha<u></u> Tail"
		let harness = try await CoordinatorBridgeHarness(source: "Seed")
		harness.focusWebView()
		harness.coordinator.parent = MarkdownWebView(
			text: formatted, theme: .default, fontSize: 15)
			.editable(true)
			.caretTarget(MarkdownCaretTarget(offset: 12, token: 704))
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
			  key: '\(key)', bubbles: true, cancelable: true
			})
			if (document.body.dispatchEvent(arrow)) {
			  window.getSelection().modify('move', '\(direction)', 'character')
			}
			""")
		try await harness.type("X")
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		#expect(harness.source == expected, "direction=\(direction)")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test(arguments: [
		(caret: 4, key: "ArrowLeft", direction: "backward",
		 expected: "XA<u></u><u></u>B"),
		(caret: 4, key: "ArrowRight", direction: "forward",
		 expected: "A<u></u><u></u>BX"),
		(caret: 8, key: "ArrowLeft", direction: "backward",
		 expected: "XA<u></u><u></u>B"),
		(caret: 8, key: "ArrowRight", direction: "forward",
		 expected: "A<u></u><u></u>BX"),
		(caret: 11, key: "ArrowLeft", direction: "backward",
		 expected: "XA<u></u><u></u>B"),
		(caret: 15, key: "ArrowRight", direction: "forward",
		 expected: "A<u></u><u></u>BX"),
	])
	func arrowingFromAdjacentRestoredEmptyUnderlinesMovesByAVisibleCharacter(
		caret: Int,
		key: String,
		direction: String,
		expected: String
	) async throws {
		let source = "A<u></u><u></u>B"
		let harness = try await CoordinatorBridgeHarness(source: "Seed")
		harness.focusWebView()
		harness.coordinator.parent = MarkdownWebView(
			text: source, theme: .default, fontSize: 15)
			.editable(true)
			.caretTarget(MarkdownCaretTarget(offset: caret, token: 711))
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
				""") == String(caret)
		}
		harness.rewireRoundTrip()
		try await harness.run("""
			var arrow = new KeyboardEvent('keydown', {
			  key: '\(key)', bubbles: true, cancelable: true
			})
			if (document.body.dispatchEvent(arrow)) {
			  window.getSelection().modify('move', '\(direction)', 'character')
			}
			""")
		try await harness.type("X")
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		#expect(harness.source == expected, "key=\(key), caret=\(caret)")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test(arguments: [
		(source: "<u></u>Tail", caret: 7, key: "ArrowLeft",
		 direction: "backward", expected: "<u></u>XTail"),
		(source: "Head<u></u>", caret: 11, key: "ArrowRight",
		 direction: "forward", expected: "Head<u></u>X"),
	])
	func arrowingAcrossARestoredEmptyWrapperAtADocumentEdgeKeepsTypingOutsideIt(
		source: String,
		caret: Int,
		key: String,
		direction: String,
		expected: String
	) async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Seed")
		harness.focusWebView()
		harness.coordinator.parent = MarkdownWebView(
			text: source, theme: .default, fontSize: 15)
			.editable(true)
			.caretTarget(MarkdownCaretTarget(offset: caret, token: 708))
			.onSourceEdit { [weak harness] newText, _ in
				harness?.recordExternalEdit(newText)
			}
		harness.coordinator.applyCaretTarget()
		harness.coordinator.load(into: harness.webView)
		harness.adoptHostText(source)
		try await harness.waitUntil("full-navigation edge caret") {
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
			  key: '\(key)', bubbles: true, cancelable: true
			})
			if (document.body.dispatchEvent(arrow)) {
			  window.getSelection().modify('move', '\(direction)', 'character')
			}
			""")
		try await harness.type("X")
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		#expect(harness.source == expected, "key=\(key)")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test(arguments: [
		(command: "bold", formatted: "<u>**X**</u>"),
		(command: "italic", formatted: "<u>*X*</u>"),
		(command: "strikeThrough", formatted: "<u>~~X~~</u>"),
	])
	func nativeFormattingInsideAnEmptyUnderlineCaretNestsAndRemainsTypable(
		command: String,
		formatted: String
	) async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha Tail")
		try await harness.batch([
			"window.__mdPlaceCaret(5)",
			"window.__mdApplyFormat('underline')",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		try await harness.run("document.execCommand('\(command)')")
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()
		try await harness.type("X")
		try await harness.waitForSourceEdits(3)
		try await harness.waitQuiescent()

		#expect(harness.source == "Alpha\(formatted) Tail")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test(arguments: [
		(command: "bold", formatted: "**X**"),
		(command: "italic", formatted: "*X*"),
		(command: "strikeThrough", formatted: "~~X~~"),
	])
	func nativeFormattingAfterAHostRestoredEmptyUnderlineStaysOutsideIt(
		command: String,
		formatted: String
	) async throws {
		let source = "Alpha<u></u> Tail"
		let harness = try await CoordinatorBridgeHarness(source: "Seed")
		harness.focusWebView()
		harness.coordinator.parent = MarkdownWebView(
			text: source, theme: .default, fontSize: 15)
			.editable(true)
			.caretTarget(MarkdownCaretTarget(offset: 12, token: 709))
			.onSourceEdit { [weak harness] newText, _ in
				harness?.recordExternalEdit(newText)
			}
		harness.coordinator.applyCaretTarget()
		harness.coordinator.load(into: harness.webView)
		harness.adoptHostText(source)
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
		try await harness.run("document.execCommand('\(command)')")
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		try await harness.type("X")
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()

		#expect(harness.source == "Alpha<u></u>\(formatted) Tail")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test(arguments: [
		(command: "insertParagraph", expected: "Alpha\n\nX Tail"),
		(command: "insertLineBreak", expected: "Alpha\\\nXTail"),
	])
	func lineBreaksFromAnEmptyUnderlineCaretExitTheEmptyWrapperCleanly(
		command: String,
		expected: String
	) async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha Tail")
		try await harness.batch([
			"window.__mdPlaceCaret(5)",
			"window.__mdApplyFormat('underline')",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		try await harness.run("document.execCommand('\(command)')")
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()
		try await harness.type("X")
		try await harness.waitForSourceEdits(3)
		try await harness.waitQuiescent()

		#expect(harness.source == expected)
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test(arguments: [
		(command: "insertParagraph", expected: "Alpha<u></u>\n\nX Tail"),
		(command: "insertLineBreak", expected: "Alpha<u></u>\\\nXTail"),
	])
	func lineBreaksAfterAHostRestoredEmptyUnderlineStayAfterTheWrapper(
		command: String,
		expected: String
	) async throws {
		let formatted = "Alpha<u></u> Tail"
		let harness = try await CoordinatorBridgeHarness(source: "Seed")
		harness.focusWebView()
		harness.coordinator.parent = MarkdownWebView(
			text: formatted, theme: .default, fontSize: 15)
			.editable(true)
			.caretTarget(MarkdownCaretTarget(offset: 12, token: 707))
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
		try await harness.run("document.execCommand('\(command)')")
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		try await harness.type("X")
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()

		#expect(harness.source == expected, "command=\(command)")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func deletionThatActivatesAThematicBreakRerenders() async throws {
		let harness = try await CoordinatorBridgeHarness(
			source: "Term\n--x-\n\nTail")
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

		#expect(harness.source == "Term\n---\n\nTail")
		let fresh = try await CoordinatorBridgeHarness(source: harness.source)
		let liveVisible = EditBridgeFuzzTests.normalizedVisibleText(
			try await harness.domVisibleText())
		let freshVisible = EditBridgeFuzzTests.normalizedVisibleText(
			try await fresh.domVisibleText())
		#expect(liveVisible == freshVisible,
			"live \(liveVisible.debugDescription), fresh \(freshVisible.debugDescription)")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(try await harness.stampMismatches() == [])
	}

	@Test(arguments: [
		(source: "| A |\n|x---|\n\nTail", expected: "| A |\n|---|\n\nTail"),
		(source: "| A |\n  |x---|\n\nTail", expected: "| A |\n  |---|\n\nTail"),
	])
	func deletionThatActivatesATableDelimiterRowRerenders(
		source: String,
		expected: String
	) async throws {
		let harness = try await CoordinatorBridgeHarness(source: source)
		let deletionOffset = (source as NSString).range(of: "x").location
		try await harness.run("""
			window.__mdPlaceCaret(\(deletionOffset), 1)
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

		#expect(harness.source == expected)
		let fresh = try await CoordinatorBridgeHarness(source: harness.source)
		let liveVisible = EditBridgeFuzzTests.normalizedVisibleText(
			try await harness.domVisibleText())
		let freshVisible = EditBridgeFuzzTests.normalizedVisibleText(
			try await fresh.domVisibleText())
		#expect(liveVisible == freshVisible,
			"live \(liveVisible.debugDescription), fresh \(freshVisible.debugDescription)")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func typingBeforeHiddenDelimiterRefreshesNewlyLiteralTail() async throws {
		let source = "xt b3e**ta wa**o\"**rds *\"*** g3"
		let harness = try await CoordinatorBridgeHarness(source: source)
		let caret = (source as NSString).range(of: "*\"***").location
		try await harness.type("é", at: caret)
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		#expect(harness.source == "xt b3e**ta wa**o\"**rds é*\"*** g3")
		let live = Self.compactVisible(try await harness.domVisibleText())
		let fresh = try await CoordinatorBridgeHarness(source: harness.source)
		let rendered = Self.compactVisible(try await fresh.domVisibleText())
		#expect(live == rendered, "live \(live.debugDescription), rendered \(rendered.debugDescription)")
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func replacingWholeStyledRunBackwardDoesNotNeedRecovery() async throws {
		let source = "before **é** after"
		let harness = try await CoordinatorBridgeHarness(source: source)
		let selected = (source as NSString).range(of: "é")
		try await harness.batch([
			"window.__mdPlaceCaret(\(selected.location), \(selected.length))",
			"var r = window.getSelection().getRangeAt(0).cloneRange()",
			"window.getSelection().setBaseAndExtent(r.endContainer, r.endOffset, r.startContainer, r.startOffset)",
			"document.execCommand('insertText', false, 'é')",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		#expect(harness.source == source)
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
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
