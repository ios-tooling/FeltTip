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
