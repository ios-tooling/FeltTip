//
//  EditBridgeMixedSelectionTests.swift
//  MarkDownRangeTests
//
//  Formatting a backward selection that crosses stamped inline runs exercises
//  the page's DOM-to-source range mapping, the structural splice, selection
//  restore, and the next edit against the patched stamps.
//

#if os(macOS)
import Testing
@testable import MarkDownRange

@Suite(.serialized) @MainActor struct EditBridgeMixedSelectionTests {
	private func assertBackwardToggle(
		command: String,
		sourceLocation: SourceLocation = #_sourceLocation
	) async throws {
		let source = "Alpha **Beta** Gamma"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.batch([
			"window.__mdPlaceCaret(12)",
			"var sel = window.getSelection()",
			"for (var i = 0; i < 10; i++) sel.modify('extend', 'backward', 'character')",
			"document.execCommand('\(command)')",
		])
		try await harness.waitUntil("unsafe wrap veto") {
			harness.coordinator.vetoedEdits == 1
		}
		#expect(harness.source == source, sourceLocation: sourceLocation)
		#expect(try await harness.stampMismatches() == [], sourceLocation: sourceLocation)
		#expect(harness.coordinator.resyncCount == 0, sourceLocation: sourceLocation)
		#expect(harness.coordinator.hardRejections == 0, sourceLocation: sourceLocation)

		try await harness.type("Q", at: 0)
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "Q" + source, sourceLocation: sourceLocation)
		try await harness.waitQuiescent()
		#expect(try await harness.stampMismatches() == [], sourceLocation: sourceLocation)
	}

	@Test func boldAcrossMixedRunsWithBackwardSelection() async throws {
		try await assertBackwardToggle(command: "bold")
	}

	@Test func italicAcrossMixedRunsWithBackwardSelection() async throws {
		try await assertBackwardToggle(command: "italic")
	}

	@Test func strikethroughAcrossMixedRunsWithBackwardSelection() async throws {
		try await assertBackwardToggle(command: "strikeThrough")
	}

	@Test func everyMenuInlineCommandSafelyVetoesMixedRunSelections() async throws {
		let commands: [MarkdownFormattingCommand] = [
			.bold, .italic, .underline, .strikethrough, .inlineCode,
			.highlight, .superscript, .subscriptText, .link,
		]
		for command in commands {
			let source = "Alpha **Beta** Gamma"
			let harness = try await CoordinatorBridgeHarness(source: source)
			try await harness.batch([
				"window.__mdPlaceCaret(12)",
				"var selection = window.getSelection()",
				"for (var index = 0; index < 10; index++) selection.modify('extend', 'backward', 'character')",
				"window.__mdApplyFormat('\(command.rawValue)')",
			])
			try await harness.waitUntil("mixed \(command) veto") {
				harness.coordinator.vetoedEdits == 1
			}
			#expect(harness.source == source, "mixed selection changed source for \(command)")
			#expect(harness.sourceEditCount == 0)
			#expect(try await harness.stampMismatches() == [])
			#expect(harness.coordinator.resyncCount == 0)
			#expect(harness.coordinator.hardRejections == 0)

			try await harness.type("Q", at: 0)
			try await harness.waitForSourceEdits(1)
			#expect(harness.source == "Q" + source)
		}
	}
}
#endif
