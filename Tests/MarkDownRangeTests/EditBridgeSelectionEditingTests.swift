//
//  EditBridgeSelectionEditingTests.swift
//  MarkDownRangeTests
//
//  Selection geometry is supplied by WebKit, not the Markdown parser. Exercise
//  forward/backward selections, cross-block source spans, element-boundary
//  positions, and the next edit after each structural replacement against the
//  real coordinator and WKWebView.
//

import Foundation
import Testing
@testable import MarkDownRange

@Suite(.serialized) @MainActor struct EditBridgeSelectionEditingTests {
	private enum Direction: String, CaseIterable {
		case forward
		case backward
	}

	private struct EditCase {
		let name: String
		let source: String
		let selectedSource: String
		let replacement: String
	}

	private func json(_ string: String) -> String {
		String(data: try! JSONEncoder().encode(string), encoding: .utf8)!
	}

	private func selectionCommands(start: Int, length: Int, direction: Direction) -> [String] {
		var commands = ["window.__mdPlaceCaret(\(start), \(length))"]
		if direction == .backward {
			commands += [
				"var selectedRange = window.getSelection().getRangeAt(0).cloneRange()",
				"window.getSelection().setBaseAndExtent(selectedRange.endContainer, selectedRange.endOffset, selectedRange.startContainer, selectedRange.startOffset)",
			]
		}
		return commands
	}

	private func assertHealthy(
		_ harness: CoordinatorBridgeHarness,
		allowedResyncs: Int = 0,
		sourceLocation: SourceLocation = #_sourceLocation
	) async throws {
		try await harness.waitQuiescent()
		#expect(try await harness.stampMismatches() == [], sourceLocation: sourceLocation)
		#expect(harness.coordinator.resyncCount <= allowedResyncs, sourceLocation: sourceLocation)
		#expect(harness.coordinator.vetoedEdits == 0, sourceLocation: sourceLocation)
		#expect(harness.coordinator.hardRejections == 0, sourceLocation: sourceLocation)
		#expect(harness.coordinator.bridgeIncidents == [], sourceLocation: sourceLocation)
	}

	private func assertReplacement(
		_ item: EditCase,
		direction: Direction,
		sourceLocation: SourceLocation = #_sourceLocation
	) async throws {
		let range = (item.source as NSString).range(of: item.selectedSource)
		#expect(range.location != NSNotFound, "missing fixture selection for \(item.name)", sourceLocation: sourceLocation)
		let expected = (item.source as NSString).replacingCharacters(in: range, with: item.replacement)
		let harness = try await CoordinatorBridgeHarness(source: item.source)
		var commands = selectionCommands(start: range.location, length: range.length, direction: direction)
		commands.append("document.execCommand('insertText', false, \(json(item.replacement)))")
		try await harness.batch(commands)
		try await harness.waitForSourceEdits(1)

		#expect(harness.source == expected, "\(item.name), \(direction.rawValue)", sourceLocation: sourceLocation)
		#expect(harness.lastCaretHint == range.location + (item.replacement as NSString).length,
				"\(item.name), \(direction.rawValue)", sourceLocation: sourceLocation)
		try await assertHealthy(harness, sourceLocation: sourceLocation)

		// Structural selection edits rebuild the page and restore a collapsed
		// caret. Type without placing it again to prove that restoration is real.
		try await harness.type("Q")
		try await harness.waitForSourceEdits(2)
		let withFollowUp = (expected as NSString).replacingCharacters(
			in: NSRange(location: range.location + (item.replacement as NSString).length, length: 0),
			with: "Q")
		#expect(harness.source == withFollowUp, "\(item.name) follow-up, \(direction.rawValue)",
				sourceLocation: sourceLocation)
		try await assertHealthy(harness, sourceLocation: sourceLocation)
	}

	/// Whether the character on each side of `location` in `text` is
	/// whitespace — the shape that invites WebKit's whitespace rebalancing.
	private func leavesWhitespacePair(_ text: String, at location: Int) -> Bool {
		let ns = text as NSString
		guard location > 0, location < ns.length else { return false }
		let whitespace = CharacterSet.whitespacesAndNewlines
		return whitespace.contains(Unicode.Scalar(ns.character(at: location - 1))!)
			&& whitespace.contains(Unicode.Scalar(ns.character(at: location))!)
	}

	private func assertDeletion(
		source: String,
		selectedSource: String,
		direction: Direction,
		sourceLocation: SourceLocation = #_sourceLocation
	) async throws {
		let range = (source as NSString).range(of: selectedSource)
		#expect(range.location != NSNotFound, sourceLocation: sourceLocation)
		let expected = (source as NSString).replacingCharacters(in: range, with: "")
		let harness = try await CoordinatorBridgeHarness(source: source)
		var commands = selectionCommands(start: range.location, length: range.length, direction: direction)
		commands.append("document.execCommand('delete')")
		try await harness.batch(commands)
		try await harness.waitForSourceEdits(1)

		#expect(harness.source == expected, "\(direction.rawValue) delete", sourceLocation: sourceLocation)
		#expect(harness.lastCaretHint == range.location, sourceLocation: sourceLocation)
		// A delete that leaves whitespace touching whitespace is the one shape
		// WebKit is entitled to tidy: iOS rebalances the run so the DOM holds
		// one space where the source holds two. The bridge notices the drift
		// and re-renders rather than mapping from a run it can no longer
		// trust, so a single resync here is the design working, not a fault.
		// macOS leaves the DOM alone and takes the fast path.
		try await assertHealthy(
			harness,
			allowedResyncs: leavesWhitespacePair(expected, at: range.location) ? 1 : 0,
			sourceLocation: sourceLocation)
		try await harness.type("Q")
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == (expected as NSString).replacingCharacters(
			in: NSRange(location: range.location, length: 0), with: "Q"),
			sourceLocation: sourceLocation)
	}

	@Test func backspaceDeletesASelectionInsideAFencedCodeBlock() async throws {
		let source = "```swift\nlet value = 1\nprint(value)\n```\n"
		let selected = "value = 1"
		let range = (source as NSString).range(of: selected)
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.run("window.__mdPlaceCaret(\(range.location), \(range.length))")
		try await harness.deleteBackward()
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "```swift\nlet \nprint(value)\n```\n")
		// The deletion ends at a trailing space, which is the case iOS WebKit
		// rebalances: the run comes back shorter than the source it is stamped
		// for, the queued edit's check catches the drift, and the bridge
		// resyncs from the spliced source. macOS keeps the fast path.
		#if os(macOS)
			try await assertHealthy(harness)
		#else
			try await assertHealthy(harness, allowedResyncs: 1)
		#endif
	}

	@Test func backspaceDeletesAWholeCodeDOMSelection() async throws {
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
		try await harness.deleteBackward()
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "```swift\n```\n")
		try await assertHealthy(harness)
	}

	@Test func backspaceUsesTheLiveCodeSelectionWhenWebKitReportsACollapsedTarget() async throws {
		let source = "```swift\nlet value = 1\nprint(value)\n```\n"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.run("""
			var code = document.querySelector('pre code')
			var selected = document.createRange()
			selected.selectNodeContents(code)
			var selection = window.getSelection()
			selection.removeAllRanges()
			selection.addRange(selected)
			var target = selected.cloneRange()
			target.collapse(true)
			var event = new InputEvent('beforeinput', {
			  inputType: 'deleteContentBackward', bubbles: true, cancelable: true
			})
			Object.defineProperty(event, 'getTargetRanges', {
			  value: function () { return [target] }
			})
			var allowed = document.body.dispatchEvent(event)
			if (allowed) {
			  selected.deleteContents()
			  document.body.dispatchEvent(new InputEvent('input', {
			    inputType: 'deleteContentBackward', bubbles: true
			  }))
			}
			""")
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "```swift\n```\n")
		try await assertHealthy(harness)
	}

	@Test func physicalDeleteKeysClearAWholeFencedCodeSelectionWithoutBeeping() async throws {
		for key in ["Backspace", "Delete"] {
			let source = "```swift\nlet value = 1\nprint(value)\n```\n"
			let harness = try await CoordinatorBridgeHarness(source: source)
			try await harness.run("""
				var code = document.querySelector('pre code')
				var range = document.createRange()
				range.selectNodeContents(code)
				var selection = window.getSelection()
				selection.removeAllRanges()
				selection.addRange(range)
				var keyEvent = new KeyboardEvent('keydown', {
				  key: '\(key)', bubbles: true, cancelable: true
				})
				window.__deleteKeyHandled = !document.dispatchEvent(keyEvent)
				""")
			#expect(try await harness.evaluate("window.__deleteKeyHandled ? 'yes' : 'no'") == "yes", "key=\(key)")
			try await harness.waitForSourceEdits(1)
			#expect(harness.source == "```swift\n```\n", "key=\(key)")
			try await assertHealthy(harness)
		}
	}

	@Test func physicalDeleteStillWorksAfterHostUndoRestoresTheCodeBlock() async throws {
		let source = "```swift\nlet value = 1\nprint(value)\n```\n"
		let harness = try await CoordinatorBridgeHarness(source: source)
		func selectAndDelete() async throws {
			try await harness.run("""
				var code = document.querySelector('pre code')
				var range = document.createRange()
				range.selectNodeContents(code)
				var selection = window.getSelection()
				selection.removeAllRanges()
				selection.addRange(range)
				document.dispatchEvent(new KeyboardEvent('keydown', {
				  key: 'Backspace', bubbles: true, cancelable: true
				}))
				""")
		}

		try await selectAndDelete()
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "```swift\n```\n")
		try await harness.waitQuiescent()

		// Emulate Marker undo: restore the prior source with a token-gated caret,
		// re-render, then make a fresh mouse-like selection and delete again.
		harness.focusWebView()
		harness.coordinator.parent = MarkdownWebView(text: source, theme: .default, fontSize: 14)
			.editable(true)
			.caretTarget(MarkdownCaretTarget(offset: 9, token: 1))
			.onSourceEdit { [weak harness] newText, _ in harness?.recordExternalEdit(newText) }
		harness.coordinator.applyCaretTarget()
		harness.coordinator.load(into: harness.webView)
		harness.adoptHostText(source)
		try await harness.waitQuiescent()
		harness.rewireRoundTrip()
		let resyncsAfterUndo = harness.coordinator.resyncCount
		let rejectionsAfterUndo = harness.coordinator.hardRejections

		try await selectAndDelete()
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == "```swift\n```\n")
		try await harness.waitQuiescent()
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == resyncsAfterUndo)
		#expect(harness.coordinator.hardRejections == rejectionsAfterUndo)
	}

	@Test func replacingSelectionsWorksInBothDirectionsAcrossEveryMajorGeometry() async throws {
		let cases = [
			EditCase(
				name: "single run",
				source: "Zero alpha bravo charlie omega",
				selectedSource: "alpha bravo charlie",
				replacement: "X"),
			EditCase(
				name: "paragraph boundary",
				source: "Zero alpha\n\nbravo charlie\n\nOmega",
				selectedSource: "alpha\n\nbravo",
				replacement: "middle"),
			EditCase(
				name: "balanced styled run",
				source: "Zero alpha **bravo** charlie omega",
				selectedSource: "alpha **bravo** charlie",
				replacement: "middle"),
			EditCase(
				name: "balanced link",
				source: "Zero before [label](https://example.com/a_(b)) after omega",
				selectedSource: "before [label](https://example.com/a_(b)) after",
				replacement: "linked"),
			EditCase(
				name: "UTF-16 and combining text",
				source: "Zero café 😀 e\u{301} bravo omega",
				selectedSource: "café 😀 e\u{301} bravo",
				replacement: "🙂"),
			EditCase(
				name: "heading through list item",
				source: "# Heading words\n\n- first item\n- second item\n\nTail",
				selectedSource: "Heading words\n\n- first item",
				replacement: "Replaced"),
		]
		for item in cases {
			for direction in Direction.allCases {
				try await assertReplacement(item, direction: direction)
			}
		}
	}

	@Test func typingOverStyledBoundaryEndpointsConsumesOwnedHiddenSyntax() async throws {
		let source = "Before **Alpha** and _Beta_ after"
		let start = (source as NSString).range(of: "Alpha").location
		let beta = (source as NSString).range(of: "Beta")
		for direction in Direction.allCases {
			let harness = try await CoordinatorBridgeHarness(source: source)
			var commands = selectionCommands(
				start: start,
				length: beta.upperBound - start,
				direction: direction)
			commands.append("document.execCommand('insertText', false, 'X')")
			try await harness.batch(commands)
			try await harness.waitForSourceEdits(1)

			#expect(harness.source == "Before X after")
			#expect(harness.lastCaretHint == ("Before X" as NSString).length)
			try await assertHealthy(harness)
			try await harness.type("!")
			try await harness.waitForSourceEdits(2)
			#expect(harness.source == "Before X! after")
			try await assertHealthy(harness)
		}
	}

	@Test func typingAcrossNestedStyledEndpointsConsumesEveryOwnedDelimiter() async throws {
		let cases = [
			(source: "[**Alpha**](https://example.com) and ~~Beta~~ Tail", expected: "X Tail"),
			(source: "<u>**Alpha**</u> and [Beta](https://example.com) Tail", expected: "X Tail"),
			(source: "~~**Alpha**~~ and _Beta_ Tail", expected: "X Tail"),
		]
		for item in cases {
			let start = (item.source as NSString).range(of: "Alpha").location
			let beta = (item.source as NSString).range(of: "Beta")
			for direction in Direction.allCases {
				let harness = try await CoordinatorBridgeHarness(source: item.source)
				var commands = selectionCommands(
					start: start,
					length: beta.upperBound - start,
					direction: direction)
				commands.append("document.execCommand('insertText', false, 'X')")
				try await harness.batch(commands)
				try await harness.waitForSourceEdits(1)

				#expect(harness.source == item.expected)
				#expect(harness.lastCaretHint == 1)
				try await assertHealthy(harness)
				try await harness.type("!")
				try await harness.waitForSourceEdits(2)
				#expect(harness.source == "X! Tail")
				try await assertHealthy(harness)
			}
		}
	}

	@Test func typingBurstAfterCrossRunReplacementReplaysAfterCaretRestore() async throws {
		let source = "Before **Alpha** and _Beta_ after"
		let start = (source as NSString).range(of: "Alpha").location
		let beta = (source as NSString).range(of: "Beta")
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.batch([
			"window.__mdPlaceCaret(\(start), \(beta.upperBound - start))",
			"document.execCommand('insertText', false, 'X')",
			"document.execCommand('insertText', false, '!')",
			"document.execCommand('insertText', false, '?')",
			"document.execCommand('insertText', false, 'Z')",
		])

		try await harness.waitForSourceEdits(2)
		#expect(harness.source == "Before X!?Z after")
		#expect(harness.lastCaretHint == ("Before X!?Z" as NSString).length)
		try await assertHealthy(harness)
	}

	@Test func unicodeTypingBurstAfterCrossRunReplacementKeepsUTF16CaretExact() async throws {
		let source = "Before **Alpha** and _Beta_ after Tail"
		let start = (source as NSString).range(of: "Alpha").location
		let beta = (source as NSString).range(of: "Beta")
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.batch([
			"window.__mdPlaceCaret(\(start), \(beta.upperBound - start))",
			"document.execCommand('insertText', false, 'X')",
			"document.execCommand('insertText', false, '😀')",
			"document.execCommand('insertText', false, 'e\\u0301')",
		])

		try await harness.waitForSourceEdits(2)
		let expectedPrefix = "Before X😀e\u{301}"
		#expect(harness.source == expectedPrefix + " after Tail")
		#expect(harness.lastCaretHint == (expectedPrefix as NSString).length)
		try await assertHealthy(harness)

		try await harness.type("!", at: (harness.source as NSString).range(of: "Tail").upperBound)
		try await harness.waitForSourceEdits(3)
		#expect(harness.source.hasSuffix("Tail!"))
		try await assertHealthy(harness)
	}

	@Test func partialStyledSelectionsNeverConsumeAnUnselectedDelimiter() async throws {
		let cases = [
			(selected: "Al", replacement: "X", expected: "Before **Xpha** after"),
			(selected: "ha", replacement: "", expected: "Before **Alp** after"),
		]
		let source = "Before **Alpha** after"
		for item in cases {
			let range = (source as NSString).range(of: item.selected)
			for direction in Direction.allCases {
				let harness = try await CoordinatorBridgeHarness(source: source)
				var commands = selectionCommands(
					start: range.location,
					length: range.length,
					direction: direction)
				commands.append(
					"document.execCommand('insertText', false, \(json(item.replacement)))")
				try await harness.batch(commands)
				try await harness.waitForSourceEdits(1)

				#expect(harness.source == item.expected)
				try await assertHealthy(harness)
			}
		}
	}

	@Test func deletingSelectionsWorksInBothDirectionsAcrossRunsAndBlocks() async throws {
		let cases = [
			("Zero alpha bravo omega", "alpha bravo"),
			("Zero alpha\n\nbravo omega", "alpha\n\nbravo"),
			("Zero alpha **bravo** charlie omega", "alpha **bravo** charlie"),
			("Zero > quote is plain\n\nTail", "quote is plain\n\n"),
			("Zero café 😀 bravo\n\nTail", "café 😀 bravo"),
		]
		for (source, selected) in cases {
			for direction in Direction.allCases {
				try await assertDeletion(source: source, selectedSource: selected, direction: direction)
			}
		}
	}

	@Test func replacingTheReportedDocumentSelectionAcrossAnHTMLBreakIsExact() async throws {
		let item = EditCase(
			name: "lazy continuation with HTML breaks",
			source: """
			2. **Timeline** - /app/lib/timeline<br />
			This view is displayed when an item is selected. <br/>
			When an event is visible, the user can access the ArticlePage.

			Tail
			""",
			selectedSource: """
			This view is displayed when an item is selected. <br/>
			When an event is visible, the user can access the
			""",
			replacement: "Open")
		for direction in Direction.allCases {
			try await assertReplacement(item, direction: direction)
		}
	}

	@Test func selectionStartAtAListChildBoundaryUsesTheFollowingRun() async throws {
		let source = """
		2. **Timeline** - route<br />
		First continuation line.<br/>
		Second continuation line.

		Tail
		"""
		let selectedSource = "First continuation line.<br/>\nSecond"
		let sourceRange = (source as NSString).range(of: selectedSource)
		let expected = (source as NSString).replacingCharacters(in: sourceRange, with: "X")
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.run("""
			var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT)
			var firstNode = null, secondNode = null
			while (walker.nextNode()) {
			  if (!firstNode && walker.currentNode.nodeValue.indexOf('First continuation') >= 0) firstNode = walker.currentNode
			  if (!secondNode && walker.currentNode.nodeValue.indexOf('Second continuation') >= 0) secondNode = walker.currentNode
			}
			var listItem = firstNode.parentElement.closest('li')
			var firstChild = firstNode
			while (firstChild.parentNode !== listItem) firstChild = firstChild.parentNode
			var range = document.createRange()
			range.setStart(listItem, Array.prototype.indexOf.call(listItem.childNodes, firstChild))
			range.setEnd(secondNode, secondNode.nodeValue.indexOf('Second') + 6)
			var selection = window.getSelection()
			selection.removeAllRanges()
			selection.addRange(range)
			document.execCommand('insertText', false, 'X')
			""")
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == expected)
		#expect(harness.lastCaretHint == sourceRange.location + 1)
		try await assertHealthy(harness)
	}

	@Test func selectionEndAtAListChildBoundaryUsesThePrecedingRun() async throws {
		let source = """
		2. **Timeline** - route<br />
		First continuation line.<br/>
		Second continuation line.

		Tail
		"""
		let sourceRange = (source as NSString).range(of: "First continuation line.")
		let expected = (source as NSString).replacingCharacters(in: sourceRange, with: "X")
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.run("""
			var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT)
			var firstNode = null
			while (walker.nextNode()) {
			  if (walker.currentNode.nodeValue.indexOf('First continuation') >= 0) { firstNode = walker.currentNode; break }
			}
			var listItem = firstNode.parentElement.closest('li')
			var firstChild = firstNode
			while (firstChild.parentNode !== listItem) firstChild = firstChild.parentNode
			var afterFirst = Array.prototype.indexOf.call(listItem.childNodes, firstChild) + 1
			var range = document.createRange()
			range.setStart(firstNode, firstNode.nodeValue.indexOf('First'))
			range.setEnd(listItem, afterFirst)
			var selection = window.getSelection()
			selection.removeAllRanges()
			selection.addRange(range)
			document.execCommand('insertText', false, 'X')
			""")
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == expected)
		#expect(harness.lastCaretHint == sourceRange.location + 1)
		try await assertHealthy(harness)
	}

	@Test func collapsedCaretAtAListChildBoundaryUsesForwardAffinity() async throws {
		let source = """
		2. **Timeline** - route<br />
		First continuation line.<br/>
		Second continuation line.

		Tail
		"""
		let insertion = (source as NSString).range(of: "Second continuation").location
		let expected = (source as NSString).replacingCharacters(
			in: NSRange(location: insertion, length: 0), with: "X")
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.run("""
			var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT)
			var secondNode = null
			while (walker.nextNode()) {
			  if (walker.currentNode.nodeValue.indexOf('Second continuation') >= 0) { secondNode = walker.currentNode; break }
			}
			var listItem = secondNode.parentElement.closest('li')
			var secondChild = secondNode
			while (secondChild.parentNode !== listItem) secondChild = secondChild.parentNode
			var boundary = Array.prototype.indexOf.call(listItem.childNodes, secondChild)
			var range = document.createRange()
			range.setStart(listItem, boundary)
			range.collapse(true)
			var selection = window.getSelection()
			selection.removeAllRanges()
			selection.addRange(range)
			document.execCommand('insertText', false, 'X')
			""")
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == expected)
		#expect(harness.lastCaretHint == insertion + 1)
		try await assertHealthy(harness)
	}

	@Test func enterOverAForwardOrBackwardMultiBlockSelectionRestoresATypableCaret() async throws {
		let source = "Alpha bravo\n\nCharlie delta\n\nTail"
		let selected = "bravo\n\nCharlie"
		let range = (source as NSString).range(of: selected)
		let expected = (source as NSString).replacingCharacters(in: range, with: "\n\n")
		for direction in Direction.allCases {
			let harness = try await CoordinatorBridgeHarness(source: source)
			var commands = selectionCommands(start: range.location, length: range.length, direction: direction)
			commands.append("document.execCommand('insertParagraph')")
			try await harness.batch(commands)
			try await harness.waitForSourceEdits(1)
			#expect(harness.source == expected, "direction \(direction.rawValue)")
			#expect(harness.lastCaretHint == range.location + 2)
			try await assertHealthy(harness)
			try await harness.type("Q")
			try await harness.waitForSourceEdits(2)
			#expect(harness.source == (expected as NSString).replacingCharacters(
				in: NSRange(location: range.location + 2, length: 0), with: "Q"))
		}
	}

	@Test func structuralBreaksUseTheLiveSelectionWhenWebKitReportsACollapsedTarget() async throws {
		let source = "Alpha bravo\n\nCharlie delta\n\nTail"
		let selected = "bravo\n\nCharlie"
		let range = (source as NSString).range(of: selected)
		let cases = [
			(inputType: "insertParagraph", replacement: "\n\n",
				expected: "Alpha \n\n delta\n\nTail"),
			(inputType: "insertLineBreak", replacement: "\\\n",
				expected: "Alpha \\\ndelta\n\nTail"),
		]

		for item in cases {
			for direction in Direction.allCases {
				let harness = try await CoordinatorBridgeHarness(source: source)
				var commands = selectionCommands(
					start: range.location,
					length: range.length,
					direction: direction)
				commands.append("""
					var live = window.getSelection().getRangeAt(0)
					var stale = document.createRange()
					stale.setStart(live.startContainer, live.startOffset)
					stale.collapse(true)
					document.addEventListener('beforeinput', function sabotage(event) {
					  Object.defineProperty(event, 'getTargetRanges', {
					    value: function () { return [stale] }
					  })
					}, { capture: true, once: true })
					document.execCommand('\(item.inputType)')
					""")
				try await harness.batch(commands)
				try await harness.waitForSourceEdits(1)

				#expect(
					harness.source == item.expected,
					"inputType=\(item.inputType), direction=\(direction.rawValue)")
				#expect(harness.lastCaretHint == range.location + (item.replacement as NSString).length)
				try await assertHealthy(harness)
			}
		}
	}
}
