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
		]
		for (source, selected, expected) in cases {
			try await assertCut(source: source, selected: selected, expected: expected)
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
}
#endif
