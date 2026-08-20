//
//  EditBridgeFormattingCommandTests.swift
//  MarkDownRangeTests
//
//  Menu formatting travels through a different JavaScript entry point than
//  native beforeinput commands. Exercise every command against the real
//  coordinator/WKWebView round trip, then edit a later block to prove the
//  patch left stamps, revision state, and the page usable.
//

import Foundation
import Testing
@testable import MarkDownRange

@Suite(.serialized) @MainActor struct EditBridgeFormattingCommandTests {
	private struct Case {
		let command: MarkdownFormattingCommand
		let source: String
		let selection: NSRange
		let expected: String
	}

	private func apply(_ item: Case) async throws {
		let harness = try await CoordinatorBridgeHarness(source: item.source)
		try await harness.batch([
			"window.__mdPlaceCaret(\(item.selection.location), \(item.selection.length))",
			"window.__mdApplyFormat('\(item.command.rawValue)')",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		#expect(harness.source == item.expected, "failed \(item.command)")
		#expect(try await harness.stampMismatches() == [], "stamp drift after \(item.command)")
		#expect(harness.coordinator.resyncCount == 0, "resync after \(item.command)")
		#expect(harness.coordinator.hardRejections == 0, "hard rejection after \(item.command)")
		#expect(harness.coordinator.droppedStaleEdits == 0, "dropped edit after \(item.command)")

		let tail = (harness.source as NSString).range(of: "Tail")
		try await harness.type("!", at: tail.upperBound)
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()
		#expect(harness.source == item.expected.replacingOccurrences(of: "Tail", with: "Tail!"))
		#expect(try await harness.stampMismatches() == [], "later edit drift after \(item.command)")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func everyFormatMenuCommandSurvivesARealStyledRoundTrip() async throws {
		let plain = "Alpha\n\nTail"
		let alpha = (plain as NSString).range(of: "Alpha")
		let cases: [Case] = [
			.init(command: .bold, source: plain, selection: alpha, expected: "**Alpha**\n\nTail"),
			.init(command: .italic, source: plain, selection: alpha, expected: "_Alpha_\n\nTail"),
			.init(command: .underline, source: plain, selection: alpha, expected: "<u>Alpha</u>\n\nTail"),
			.init(command: .strikethrough, source: plain, selection: alpha, expected: "~~Alpha~~\n\nTail"),
			.init(command: .inlineCode, source: plain, selection: alpha, expected: "`Alpha`\n\nTail"),
			.init(command: .highlight, source: plain, selection: alpha, expected: "==Alpha==\n\nTail"),
			.init(command: .superscript, source: plain, selection: alpha, expected: "^Alpha^\n\nTail"),
			.init(command: .subscriptText, source: plain, selection: alpha, expected: "~Alpha~\n\nTail"),
			.init(command: .link, source: plain, selection: alpha, expected: "[Alpha]()\n\nTail"),
			.init(
				command: .paragraph,
				source: "# Alpha\n\nTail",
				selection: NSRange(location: 2, length: 5),
				expected: "Alpha\n\nTail"),
			.init(command: .heading1, source: plain, selection: alpha, expected: "# Alpha\n\nTail"),
			.init(command: .heading2, source: plain, selection: alpha, expected: "## Alpha\n\nTail"),
			.init(command: .heading3, source: plain, selection: alpha, expected: "### Alpha\n\nTail"),
			.init(command: .heading4, source: plain, selection: alpha, expected: "#### Alpha\n\nTail"),
			.init(command: .heading5, source: plain, selection: alpha, expected: "##### Alpha\n\nTail"),
			.init(command: .heading6, source: plain, selection: alpha, expected: "###### Alpha\n\nTail"),
			.init(
				command: .increaseHeading,
				source: "### Alpha\n\nTail",
				selection: NSRange(location: 4, length: 5),
				expected: "## Alpha\n\nTail"),
			.init(
				command: .decreaseHeading,
				source: "### Alpha\n\nTail",
				selection: NSRange(location: 4, length: 5),
				expected: "#### Alpha\n\nTail"),
			.init(command: .blockQuote, source: plain, selection: alpha, expected: "> Alpha\n\nTail"),
			.init(command: .bulletedList, source: plain, selection: alpha, expected: "- Alpha\n\nTail"),
			.init(command: .numberedList, source: plain, selection: alpha, expected: "1. Alpha\n\nTail"),
			.init(command: .taskList, source: plain, selection: alpha, expected: "- [ ] Alpha\n\nTail"),
			.init(command: .horizontalRule, source: plain, selection: alpha, expected: "Alpha\n---\n\nTail"),
		]
		#expect(cases.map(\.command) == MarkdownFormattingCommand.allCases)
		for item in cases {
			try await apply(item)
		}
	}

	@Test func multilineBlockCommandsMapAcrossRenderedBlocks() async throws {
		let source = "Alpha\n\nBeta\n\nTail"
		let selection = NSRange(location: 0, length: 11)
		let cases: [(MarkdownFormattingCommand, String)] = [
			(.heading2, "## Alpha\n\n## Beta\n\nTail"),
			(.blockQuote, "> Alpha\n\n> Beta\n\nTail"),
			(.bulletedList, "- Alpha\n\n- Beta\n\nTail"),
			(.numberedList, "1. Alpha\n\n2. Beta\n\nTail"),
			(.taskList, "- [ ] Alpha\n\n- [ ] Beta\n\nTail"),
		]
		for (command, expected) in cases {
			try await apply(.init(
				command: command,
				source: source,
				selection: selection,
				expected: expected))
		}
	}

	@Test func collapsedInlineCommandsLeaveATypableStyledCaret() async throws {
		let cases: [(MarkdownFormattingCommand, String, String)] = [
			(.bold, "Alpha**** Tail", "Alpha**X** Tail"),
			(.italic, "Alpha__ Tail", "Alpha_X_ Tail"),
			(.underline, "Alpha<u></u> Tail", "Alpha<u>X</u> Tail"),
			(.strikethrough, "Alpha~~~~ Tail", "Alpha~~X~~ Tail"),
			(.inlineCode, "Alpha`` Tail", "Alpha`X` Tail"),
			(.highlight, "Alpha==== Tail", "Alpha==X== Tail"),
			(.superscript, "Alpha^^ Tail", "Alpha^X^ Tail"),
			(.subscriptText, "Alpha~~ Tail", "Alpha~X~ Tail"),
			(.link, "Alpha[link text]() Tail", "Alpha[X]() Tail"),
		]
		for (command, afterCommand, afterTyping) in cases {
			let harness = try await CoordinatorBridgeHarness(source: "Alpha Tail")
			try await harness.batch([
				"window.__mdPlaceCaret(5)",
				"window.__mdApplyFormat('\(command.rawValue)')",
			])
			try await harness.waitForSourceEdits(1)
			try await harness.waitQuiescent()
			#expect(harness.source == afterCommand, "failed collapsed \(command)")
			try await harness.type("X")
			try await harness.waitForSourceEdits(2)
			try await harness.waitQuiescent()
			#expect(harness.source == afterTyping, "could not type inside collapsed \(command)")
			#expect(try await harness.stampMismatches() == [], "stamp drift after collapsed \(command)")
			#expect(harness.coordinator.resyncCount == 0)
			#expect(harness.coordinator.hardRejections == 0)
		}
	}

	@Test func styledTogglesRemoveExistingFormattingExactly() async throws {
		let cases: [Case] = [
			.init(command: .bold, source: "**Alpha**\n\nTail", selection: .init(location: 2, length: 5), expected: "Alpha\n\nTail"),
			.init(command: .italic, source: "_Alpha_\n\nTail", selection: .init(location: 1, length: 5), expected: "Alpha\n\nTail"),
			.init(command: .underline, source: "<u>Alpha</u>\n\nTail", selection: .init(location: 3, length: 5), expected: "Alpha\n\nTail"),
			.init(command: .strikethrough, source: "~~Alpha~~\n\nTail", selection: .init(location: 2, length: 5), expected: "Alpha\n\nTail"),
			.init(command: .inlineCode, source: "`Alpha`\n\nTail", selection: .init(location: 1, length: 5), expected: "Alpha\n\nTail"),
			.init(command: .highlight, source: "==Alpha==\n\nTail", selection: .init(location: 2, length: 5), expected: "Alpha\n\nTail"),
			.init(command: .superscript, source: "^Alpha^\n\nTail", selection: .init(location: 1, length: 5), expected: "Alpha\n\nTail"),
			.init(command: .subscriptText, source: "~Alpha~\n\nTail", selection: .init(location: 1, length: 5), expected: "Alpha\n\nTail"),
			.init(command: .link, source: "[Alpha]()\n\nTail", selection: .init(location: 1, length: 5), expected: "Alpha\n\nTail"),
			.init(command: .blockQuote, source: "> Alpha\n\nTail", selection: .init(location: 2, length: 5), expected: "Alpha\n\nTail"),
			.init(command: .bulletedList, source: "- Alpha\n\nTail", selection: .init(location: 2, length: 5), expected: "Alpha\n\nTail"),
			.init(command: .numberedList, source: "1. Alpha\n\nTail", selection: .init(location: 3, length: 5), expected: "Alpha\n\nTail"),
			.init(command: .taskList, source: "- [ ] Alpha\n\nTail", selection: .init(location: 6, length: 5), expected: "Alpha\n\nTail"),
		]
		for item in cases {
			try await apply(item)
		}
	}

	@Test func overlappingMenuFormatsSerializeWithoutDuplicateEdits() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha\n\nTail")
		try await harness.batch([
			"window.__mdPlaceCaret(0, 5)",
			"window.__mdApplyFormat('bold')",
			"window.__mdApplyFormat('inlineCode')",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		#expect(harness.source == "**Alpha**\n\nTail")
		#expect(harness.sourceEditCount == 1)
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)

		try await harness.run("window.__mdApplyFormat('inlineCode')")
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()
		#expect(harness.source == "**`Alpha`**\n\nTail")
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func formattingOneBlockInALargeDocumentKeepsPatchIdentityScrollAndResponsiveness() async throws {
		let paragraphs = (0..<800).map {
			"Paragraph \($0) with enough text to make this a realistically tall styled document."
		}
		let source = paragraphs.joined(separator: "\n\n")
		let harness = try await CoordinatorBridgeHarness(source: source)
		let target = (source as NSString).range(of: "Paragraph 400")
		let expected = (source as NSString).replacingCharacters(
			in: NSRange(location: target.location, length: 0),
			with: "## ")

		try await harness.run("""
			window.__testNonce = 1;
			var blocks = Array.from(document.body.children).filter(e => e.querySelector && e.querySelector('[data-s]'));
			blocks[20].dataset.testIdentity = 'before-format';
			blocks[780].dataset.testIdentity = 'after-format';
			window.scrollTo(0, blocks[400].offsetTop);
			window.__testScrollY = window.scrollY;
			""")
		let heartbeat = Task { @MainActor () -> Int in
			var ticks = 0
			while !Task.isCancelled {
				try? await Task.sleep(for: .milliseconds(1))
				ticks += 1
			}
			return ticks
		}
		try await harness.batch([
			"window.__mdPlaceCaret(\(target.location), \(target.length))",
			"window.__mdApplyFormat('heading2')",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		heartbeat.cancel()
		let ticks = await heartbeat.value

		#expect(harness.source == expected)
		#expect(ticks >= 3, "main actor only ticked \(ticks)× during a large formatting render")
		#expect(try await harness.evaluate("window.__testNonce === 1 ? 'alive' : 'gone'") == "alive")
		#expect(try await harness.evaluate(
			"document.querySelector('[data-test-identity=\"before-format\"]') && document.querySelector('[data-test-identity=\"after-format\"]') ? 'yes' : 'no'"
		) == "yes", "formatting replaced unchanged blocks")
		let scrollDelta = try await harness.evaluate(
			"String(Math.abs(window.scrollY - window.__testScrollY))").flatMap(Double.init) ?? .infinity
		#expect(scrollDelta < 60, "scroll moved \(scrollDelta)px during a one-block format")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
		#expect(try await harness.stampMismatches() == [])
	}
}
