//
//  EditBridgeCutStabilityTests.swift
//  MarkDownRangeTests
//
//  Cut is unusually risky in contentEditable: WebKit often omits target
//  ranges, and deleting visible text can leave its hidden Markdown delimiters
//  behind or unbalanced. Drive the real event and coordinator for every
//  editable inline run shape.
//

#if os(macOS)
import Foundation
import Testing
@testable import MarkDownRange

@Suite(.serialized) @MainActor struct EditBridgeCutStabilityTests {
	private func cut(
		_ harness: CoordinatorBridgeHarness,
		start: Int,
		length: Int,
		backward: Bool = false,
		backwardCharacters: Int? = nil
	) async throws {
		if backward {
			let characters = backwardCharacters ?? length
			try await harness.batch([
				"window.__mdPlaceCaret(\(start + length))",
				"var selection = window.getSelection()",
				"for (var index = 0; index < \(characters); index++) selection.modify('extend', 'backward', 'character')",
				cutEventScript,
			])
		} else {
			try await harness.batch([
				"window.__mdPlaceCaret(\(start), \(length))",
				cutEventScript,
			])
		}
	}

	private var cutEventScript: String {
		"""
		var cut = new InputEvent('beforeinput', {
		  inputType: 'deleteByCut', bubbles: true, cancelable: true
		})
		document.body.dispatchEvent(cut)
		if (!cut.defaultPrevented) {
		  window.getSelection().deleteFromDocument()
		  document.body.dispatchEvent(new InputEvent('input', {
		    inputType: 'deleteByCut', bubbles: true
		  }))
		}
		"""
	}

	private func assertCut(
		source: String,
		selected: String,
		expected: String,
		backward: Bool = false,
		backwardCharacters: Int? = nil,
		sourceLocation: SourceLocation = #_sourceLocation
	) async throws {
		let range = (source as NSString).range(of: selected)
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await cut(
			harness,
			start: range.location,
			length: range.length,
			backward: backward,
			backwardCharacters: backwardCharacters ?? selected.count)
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		#expect(harness.source == expected, sourceLocation: sourceLocation)
		#expect(try await harness.stampMismatches() == [], sourceLocation: sourceLocation)
		#expect(harness.coordinator.resyncCount == 0, sourceLocation: sourceLocation)
		#expect(harness.coordinator.hardRejections == 0, sourceLocation: sourceLocation)

		let tail = (harness.source as NSString).range(of: "Tail")
		try await harness.type("!", at: tail.upperBound)
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == expected.replacingOccurrences(of: "Tail", with: "Tail!"),
				sourceLocation: sourceLocation)
	}

	@Test func cuttingAWholeStyledRunRemovesItsHiddenSyntax() async throws {
		let cases: [(String, String, String)] = [
			("**Alpha** Tail", "Alpha", " Tail"),
			("_Alpha_ Tail", "Alpha", " Tail"),
			("<u>Alpha</u> Tail", "Alpha", " Tail"),
			("~~Alpha~~ Tail", "Alpha", " Tail"),
			("`Alpha` Tail", "Alpha", " Tail"),
			("==Alpha== Tail", "Alpha", " Tail"),
			("^Alpha^ Tail", "Alpha", " Tail"),
			("~Alpha~ Tail", "Alpha", " Tail"),
			("[Alpha](https://example.com) Tail", "Alpha", " Tail"),
			("***Alpha*** Tail", "Alpha", " Tail"),
			("**_Alpha_** Tail", "Alpha", " Tail"),
			("[**Alpha**](https://example.com) Tail", "Alpha", " Tail"),
			("~~**Alpha**~~ Tail", "Alpha", " Tail"),
			("<u>**Alpha**</u> Tail", "Alpha", " Tail"),
		]
		for (source, selected, expected) in cases {
			try await assertCut(source: source, selected: selected, expected: expected)
		}
	}

	@Test func ordinarySelectionDeleteRemovesOwnedInlineAndBlockSyntax() async throws {
		let cases: [(source: String, selected: String, expected: String)] = [
			("**Alpha** Tail", "Alpha", " Tail"),
			("~~Alpha~~ Tail", "Alpha", " Tail"),
			("`Alpha` Tail", "Alpha", " Tail"),
			("[Alpha](https://example.com) Tail", "Alpha", " Tail"),
			("~~**Alpha**~~ Tail", "Alpha", " Tail"),
			("<u>**Alpha**</u> Tail", "Alpha", " Tail"),
			("[**Alpha**](https://example.com) Tail", "Alpha", " Tail"),
			("# Alpha\n\nTail", "Alpha", "\n\nTail"),
			("> Alpha\n\nTail", "Alpha", "\n\nTail"),
			("- Alpha\n\nTail", "Alpha", "\n\nTail"),
		]
		for command in ["delete", "forwardDelete"] {
			for item in cases {
				let range = (item.source as NSString).range(of: item.selected)
				let harness = try await CoordinatorBridgeHarness(source: item.source)
				try await harness.batch([
					"window.__mdPlaceCaret(\(range.location), \(range.length))",
					"document.execCommand('\(command)')",
				])
				try await harness.waitForSourceEdits(1)
				try await harness.waitQuiescent()
				#expect(harness.source == item.expected,
					"command=\(command), source=\(item.source)")
				#expect(try await harness.stampMismatches() == [],
					"command=\(command), source=\(item.source)")
				#expect(harness.coordinator.resyncCount == 0)
				#expect(harness.coordinator.hardRejections == 0)
			}
		}
	}

	@Test func backwardCutAcrossAStyledBoundaryKeepsMarkersBalanced() async throws {
		try await assertCut(
			source: "Alpha **Beta** Gamma Tail",
			selected: "ha **Beta",
			expected: "Alp Gamma Tail",
			backward: true,
			backwardCharacters: 7)
	}

	@Test func cuttingAWholeBlockRemovesItsHiddenPrefix() async throws {
		let cases: [(String, String)] = [
			("# Alpha\n\nTail", "\n\nTail"),
			("> Alpha\n\nTail", "\n\nTail"),
			("- Alpha\n\nTail", "\n\nTail"),
			("1. Alpha\n\nTail", "\n\nTail"),
			("- [ ] Alpha\n\nTail", "\n\nTail"),
			("> - **Alpha**\n\nTail", "\n\nTail"),
			("- Parent\n  - Alpha\n  - Sibling\n- Tail", "- Parent\n  \n  - Sibling\n- Tail"),
		]
		for (source, expected) in cases {
			try await assertCut(source: source, selected: "Alpha", expected: expected)
		}
	}

	@Test func forwardCutFromAStyledRunIntoPlainTextKeepsMarkersBalanced() async throws {
		try await assertCut(
			source: "Alpha **Beta** Gamma Tail",
			selected: "Beta** Ga",
			expected: "Alpha mma Tail")
	}

	@Test func cuttingEmojiUsesUTF16OffsetsAndLeavesLaterRunsEditable() async throws {
		try await assertCut(
			source: "Alpha 😀 Beta Tail",
			selected: "😀",
			expected: "Alpha  Beta Tail",
			backward: true)
	}

	@Test func cuttingFromALazyListContinuationAcrossAnHTMLBreakUsesTheForwardBoundary() async throws {
		let source = """
		2. **Timeline** - /app/lib/timeline<br />
		This view is displayed when an item from the menu is selected: the user is presented with a vertical timeline. It can be scrolled up and down, zoomed in and out. <br/>
		When an event is in view, a bubble will be shown on screen with a custom animated widget right next to it. By tapping on either, the user can access the ArticlePage.

		Tail
		"""
		let selectedStart = "This view is displayed"
		let selectedEnd = "the ArticlePage"
		let ns = source as NSString
		let start = ns.range(of: selectedStart).location
		let endPhrase = ns.range(of: selectedEnd)
		let end = endPhrase.location + ("the" as NSString).length
		let expected = ns.replacingCharacters(
			in: NSRange(location: start, length: end - start),
			with: "")
		let harness = try await CoordinatorBridgeHarness(source: source)

		try await harness.run("""
			var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT)
			var startNode = null, endNode = null
			while (walker.nextNode()) {
			  if (!startNode && walker.currentNode.nodeValue.indexOf('This view is displayed') >= 0) startNode = walker.currentNode
			  if (!endNode && walker.currentNode.nodeValue.indexOf('the ArticlePage') >= 0) endNode = walker.currentNode
			}
			var startContainer = startNode.closest ? startNode.closest('li') : startNode.parentElement.closest('li')
			var startChild = startNode
			while (startChild.parentNode !== startContainer) startChild = startChild.parentNode
			var range = document.createRange()
			range.setStart(startContainer, Array.prototype.indexOf.call(startContainer.childNodes, startChild))
			range.setEnd(endNode, endNode.nodeValue.indexOf('the ArticlePage') + 3)
			var selection = window.getSelection()
			selection.removeAllRanges()
			selection.addRange(range)
			\(cutEventScript)
			""")

		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		#expect(harness.source == expected)
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.vetoedEdits == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}
}
#endif
