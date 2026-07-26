//
//  EditBridgeSelectionEditingTests.swift
//  MarkDownRangeTests
//
//  Selection geometry is supplied by WebKit, not the Markdown parser. Exercise
//  forward/backward selections, cross-block source spans, element-boundary
//  positions, and the next edit after each structural replacement against the
//  real coordinator and WKWebView.
//

#if os(macOS)
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
		sourceLocation: SourceLocation = #_sourceLocation
	) async throws {
		try await harness.waitQuiescent()
		#expect(try await harness.stampMismatches() == [], sourceLocation: sourceLocation)
		#expect(harness.coordinator.resyncCount == 0, sourceLocation: sourceLocation)
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
		try await assertHealthy(harness, sourceLocation: sourceLocation)
		try await harness.type("Q")
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == (expected as NSString).replacingCharacters(
			in: NSRange(location: range.location, length: 0), with: "Q"),
			sourceLocation: sourceLocation)
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
}
#endif
