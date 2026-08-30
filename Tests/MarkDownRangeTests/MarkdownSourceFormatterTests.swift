//
//  MarkdownSourceFormatterTests.swift
//  MarkDownRangeTests
//

import Foundation
import Testing
@testable import MarkDownRange

#if os(macOS)
import AppKit
#endif

@Suite struct MarkdownSourceFormatterTests {
	private func apply(
		_ command: MarkdownFormattingCommand,
		to source: String,
		selection: NSRange
	) throws -> (String, NSRange) {
		let change = try #require(MarkdownSourceFormatter.change(
			in: source,
			selection: selection,
			command: command))
		let result = (source as NSString).replacingCharacters(
			in: change.range,
			with: change.replacement)
		return (result, change.selection)
	}

	@Test func everyInlineStyleRoundTripsExactly() throws {
		let styles: [(MarkdownFormattingCommand, String)] = [
			(.bold, "**"),
			(.italic, "_"),
			(.strikethrough, "~~"),
			(.highlight, "=="),
			(.superscript, "^"),
			(.subscriptText, "~"),
		]
		for (command, marker) in styles {
			let source = "Alpha 😀 Beta"
			let selection = (source as NSString).range(of: "😀")
			let (formatted, formattedSelection) = try apply(command, to: source, selection: selection)
			#expect(formatted == "Alpha \(marker)😀\(marker) Beta", "failed \(command)")
			#expect((formatted as NSString).substring(with: formattedSelection) == "😀")

			let (restored, restoredSelection) = try apply(
				command,
				to: formatted,
				selection: formattedSelection)
			#expect(restored == source, "failed to toggle off \(command)")
			#expect(restoredSelection == selection)
		}
	}

	@Test func everyInlineStyleCreatesAnEditableCollapsedPair() throws {
		let commands: [MarkdownFormattingCommand] = [
			.bold, .italic, .underline, .strikethrough, .inlineCode,
			.highlight, .superscript, .subscriptText,
		]
		for command in commands {
			let (formatted, caret) = try apply(
				command,
				to: "Alpha",
				selection: NSRange(location: 5, length: 0))
			#expect(caret.length == 0, "failed \(command)")
			#expect(caret.location > 5, "caret was not placed inside \(command)")
			#expect(caret.location < (formatted as NSString).length, "caret escaped \(command)")
		}
	}

	@Test(arguments: [
		(command: MarkdownFormattingCommand.bold, source: "**Bravo charlie**",
		 selected: "Bravo", expected: "Bravo **charlie**"),
		(command: MarkdownFormattingCommand.bold, source: "**Bravo charlie**",
		 selected: "charlie", expected: "**Bravo** charlie"),
		(command: MarkdownFormattingCommand.italic, source: "_Bravo charlie_",
		 selected: "Bravo", expected: "Bravo _charlie_"),
		(command: MarkdownFormattingCommand.italic, source: "_Bravo charlie_",
		 selected: "charlie", expected: "_Bravo_ charlie"),
		(command: MarkdownFormattingCommand.bold, source: "**Alpha Bravo charlie**",
		 selected: "Bravo", expected: "**Alpha** Bravo **charlie**"),
		(command: MarkdownFormattingCommand.italic, source: "_Alpha Bravo charlie_",
		 selected: "Bravo", expected: "_Alpha_ Bravo _charlie_"),
		(command: MarkdownFormattingCommand.strikethrough, source: "~~Alpha Bravo charlie~~",
		 selected: "Bravo", expected: "~~Alpha~~ Bravo ~~charlie~~"),
		(command: MarkdownFormattingCommand.highlight, source: "==Alpha Bravo charlie==",
		 selected: "Bravo", expected: "==Alpha== Bravo ==charlie=="),
		(command: MarkdownFormattingCommand.superscript, source: "^Alpha Bravo charlie^",
		 selected: "Bravo", expected: "^Alpha^ Bravo ^charlie^"),
		(command: MarkdownFormattingCommand.subscriptText, source: "~Alpha Bravo charlie~",
		 selected: "Bravo", expected: "~Alpha~ Bravo ~charlie~"),
		(command: MarkdownFormattingCommand.bold, source: "**Alpha** Bravo **charlie**",
		 selected: "Bravo", expected: "**Alpha** **Bravo** **charlie**"),
	])
	func togglingAStyledRunFragmentSplitsTheRunCleanly(
		command: MarkdownFormattingCommand,
		source: String,
		selected: String,
		expected: String
	) throws {
		let selection = (source as NSString).range(of: selected)
		let (result, resultSelection) = try apply(
			command, to: source, selection: selection)
		#expect(result == expected)
		#expect((result as NSString).substring(with: resultSelection) == selected)
	}

	@Test func underlineRoundTripsItsAsymmetricHTMLMarkers() throws {
		let source = "Alpha Beta"
		let selection = (source as NSString).range(of: "Alpha")
		let (underlined, underlinedSelection) = try apply(
			.underline,
			to: source,
			selection: selection)
		#expect(underlined == "<u>Alpha</u> Beta")
		#expect((underlined as NSString).substring(with: underlinedSelection) == "Alpha")
		let (restored, restoredSelection) = try apply(
			.underline,
			to: underlined,
			selection: underlinedSelection)
		#expect(restored == source)
		#expect(restoredSelection == selection)
	}

	@Test(arguments: [
		(source: "<u>Bravo charlie</u>", selected: "Bravo",
		 expected: "Bravo <u>charlie</u>"),
		(source: "<u>Bravo charlie</u>", selected: "charlie",
		 expected: "<u>Bravo</u> charlie"),
		(source: "<u>Alpha Bravo charlie</u>", selected: "Bravo",
		 expected: "<u>Alpha</u> Bravo <u>charlie</u>"),
		(source: "<u>Alpha</u> Bravo <u>charlie</u>", selected: "Bravo",
		 expected: "<u>Alpha</u> <u>Bravo</u> <u>charlie</u>"),
	])
	func togglingAnUnderlineFragmentSplitsTheRunCleanly(
		source: String,
		selected: String,
		expected: String
	) throws {
		let selection = (source as NSString).range(of: selected)
		let (result, resultSelection) = try apply(
			.underline, to: source, selection: selection)
		#expect(result == expected)
		#expect((result as NSString).substring(with: resultSelection) == selected)
	}

	@Test func linkWrapsAndUnwrapsWithoutLosingItsLabel() throws {
		let source = "Read Marker today"
		let selection = (source as NSString).range(of: "Marker")
		let (linked, linkedSelection) = try apply(.link, to: source, selection: selection)
		#expect(linked == "Read [Marker]() today")
		#expect((linked as NSString).substring(with: linkedSelection) == "Marker")

		let label = (linked as NSString).range(of: "Marker")
		let (restored, restoredSelection) = try apply(.link, to: linked, selection: label)
		#expect(restored == source)
		#expect((restored as NSString).substring(with: restoredSelection) == "Marker")
	}

	@Test func linkToggleConsumesNestedAndEscapedDestinationParentheses() throws {
		for source in [
			"[Marker](https://example.com/(stable))",
			#"[Marker](https://example.com/a\)b)"#,
		] {
			let selection = (source as NSString).range(of: "Marker")
			let (restored, restoredSelection) = try apply(.link, to: source, selection: selection)
			#expect(restored == "Marker")
			#expect(restoredSelection == NSRange(location: 0, length: 6))
		}
	}

	@Test func allHeadingLevelsTransformEverySelectedLine() throws {
		let commands: [(MarkdownFormattingCommand, Int)] = [
			(.heading1, 1), (.heading2, 2), (.heading3, 3),
			(.heading4, 4), (.heading5, 5), (.heading6, 6),
		]
		for (command, level) in commands {
			let source = "Alpha\nBeta\n"
			let selection = NSRange(location: 0, length: 10)
			let (formatted, formattedSelection) = try apply(command, to: source, selection: selection)
			let marker = String(repeating: "#", count: level) + " "
			#expect(formatted == "\(marker)Alpha\n\(marker)Beta\n", "failed \(command)")

			let (plain, plainSelection) = try apply(
				.paragraph,
				to: formatted,
				selection: formattedSelection)
			#expect(plain == source, "paragraph failed after \(command)")
			#expect(plainSelection == selection)
		}
	}

	@Test func headingIncreaseAndDecreaseFollowTheSixLevelCycle() throws {
		let source = "### Alpha"
		let selection = (source as NSString).range(of: "Alpha")
		let (promoted, promotedSelection) = try apply(.increaseHeading, to: source, selection: selection)
		#expect(promoted == "## Alpha")
		let (demoted, demotedSelection) = try apply(
			.decreaseHeading,
			to: promoted,
			selection: promotedSelection)
		#expect(demoted == source)
		#expect(demotedSelection == selection)

		let (six, sixSelection) = try apply(
			.decreaseHeading,
			to: "###### Alpha",
			selection: NSRange(location: 7, length: 5))
		#expect(six == "Alpha")
		#expect(sixSelection == NSRange(location: 0, length: 5))
	}

	@Test func blockQuoteTogglesAcrossIndentedAndBlankLines() throws {
		let source = "Alpha\n\n  Beta\n"
		let selection = NSRange(location: 0, length: (source as NSString).length)
		let (quoted, quotedSelection) = try apply(.blockQuote, to: source, selection: selection)
		#expect(quoted == "> Alpha\n\n  > Beta\n")
		let (restored, restoredSelection) = try apply(
			.blockQuote,
			to: quoted,
			selection: quotedSelection)
		#expect(restored == source)
		#expect(restoredSelection == selection)
	}

	@Test(arguments: [
		(source: "[Bravo charlie](https://x)", selected: "Bravo",
		 expected: "Bravo [charlie](https://x)"),
		(source: "[Bravo charlie](https://x)", selected: "charlie",
		 expected: "[Bravo](https://x) charlie"),
		(source: "[Bravo charlie](https://x/a(b)/c)", selected: "Bravo",
		 expected: "Bravo [charlie](https://x/a(b)/c)"),
		(source: "[Bravo charlie](https://x/a\\)/c)", selected: "charlie",
		 expected: "[Bravo](https://x/a\\)/c) charlie"),
		(source: "[Alpha Bravo charlie](https://x)", selected: "Bravo",
		 expected: "[Alpha](https://x) Bravo [charlie](https://x)"),
		(source: "[Alpha](https://a) Bravo [charlie](https://c)", selected: "Bravo",
		 expected: "[Alpha](https://a) [Bravo]() [charlie](https://c)"),
		(source: "[[Alpha] Bravo charlie](https://x)", selected: "Bravo",
		 expected: "[[Alpha]](https://x) Bravo [charlie](https://x)"),
	])
	func togglingALinkLabelFragmentPreservesTheRemainingDestination(
		source: String,
		selected: String,
		expected: String
	) throws {
		let selection = (source as NSString).range(of: selected)
		let (result, resultSelection) = try apply(
			.link, to: source, selection: selection)
		#expect(result == expected)
		#expect((result as NSString).substring(with: resultSelection) == selected)
	}

	@Test func listCommandsConvertAndToggleMultipleLines() throws {
		let source = "Alpha\nBeta\n"
		let selection = NSRange(location: 0, length: 10)
		let cases: [(MarkdownFormattingCommand, String)] = [
			(.bulletedList, "- Alpha\n- Beta\n"),
			(.numberedList, "1. Alpha\n2. Beta\n"),
			(.taskList, "- [ ] Alpha\n- [ ] Beta\n"),
		]
		for (command, expected) in cases {
			let (formatted, formattedSelection) = try apply(command, to: source, selection: selection)
			#expect(formatted == expected, "failed \(command)")
			let (restored, restoredSelection) = try apply(
				command,
				to: formatted,
				selection: formattedSelection)
			#expect(restored == source, "failed to toggle off \(command)")
			#expect(restoredSelection == selection)
		}
	}

	@Test func listCommandsReplaceOtherListMarkersInsteadOfNestingThem() throws {
		let source = "- Alpha\n* Beta\n"
		let selection = NSRange(location: 2, length: 12)
		let (numbered, numberedSelection) = try apply(.numberedList, to: source, selection: selection)
		#expect(numbered == "1. Alpha\n2. Beta\n")
		#expect((numbered as NSString).substring(with: numberedSelection).contains("Alpha"))

		let (tasks, _) = try apply(.taskList, to: numbered, selection: numberedSelection)
		#expect(tasks == "- [ ] Alpha\n- [ ] Beta\n")
	}

	@Test func horizontalRuleInsertsWithoutDeletingTheSelection() throws {
		let source = "Alpha\nBeta"
		let selection = (source as NSString).range(of: "Alpha")
		let (formatted, caret) = try apply(.horizontalRule, to: source, selection: selection)
		#expect(formatted == "Alpha\n---\n\nBeta")
		#expect(caret == NSRange(location: 11, length: 0))
	}

	@Test func horizontalRuleAtACollapsedCaretDoesNotSplitTheCurrentLine() throws {
		let (formatted, caret) = try apply(
			.horizontalRule,
			to: "Alpha Tail",
			selection: NSRange(location: 5, length: 0))
		#expect(formatted == "Alpha Tail\n---\n")
		#expect(caret == NSRange(location: 15, length: 0))
	}

	@Test func formattingNearTheEndOfALargeDocumentTouchesOnlyThePrefix() throws {
		let source = (0..<20_000).map { "Paragraph \($0)\n" }.joined()
		let target = (source as NSString).range(of: "Paragraph 19999")
		let start = ContinuousClock.now
		let change = try #require(MarkdownSourceFormatter.change(
			in: source,
			selection: target,
			command: .heading2))
		let elapsed = ContinuousClock.now - start
		#expect(change.range.length == 0)
		#expect(change.replacement == "## ")
		#expect(elapsed < .milliseconds(80), "single-line format took \(elapsed)")
	}

	@Test func commandInventoryIsFullyCovered() {
		let covered: Set<MarkdownFormattingCommand> = [
			.bold, .italic, .underline, .strikethrough, .inlineCode, .highlight,
			.superscript, .subscriptText, .link, .paragraph,
			.heading1, .heading2, .heading3, .heading4, .heading5, .heading6,
			.increaseHeading, .decreaseHeading, .blockQuote,
			.bulletedList, .numberedList, .taskList, .horizontalRule,
		]
		#expect(covered == Set(MarkdownFormattingCommand.allCases))
	}
}

#if os(macOS)
@Suite @MainActor struct MarkdownFormattingTextViewCommandTests {
	@Test func rawViewExecutesEveryFormattingCommandThroughTheSharedEngine() {
		for command in MarkdownFormattingCommand.allCases {
			let textView = MarkdownFormattingTextView(frame: .zero)
			textView.string = command == .paragraph || command == .decreaseHeading
				? "# Alpha\nBeta"
				: "Alpha\nBeta"
			textView.setSelectedRange((textView.string as NSString).range(of: "Alpha"))
			let before = textView.string
			textView.applyFormatting(command)
			#expect(textView.string != before, "raw command did nothing: \(command)")
			#expect(textView.selectedRange().upperBound <= (textView.string as NSString).length)
		}
	}

	@Test func rawHeadingShortcutsDoNotStealFontZoomKeysOrExtraModifiers() throws {
		let textView = MarkdownFormattingTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
		let window = NSWindow(
			contentRect: textView.frame,
			styleMask: [.borderless],
			backing: .buffered,
			defer: false)
		window.contentView = textView
		window.orderFront(nil)
		try #require(window.makeFirstResponder(textView))
		textView.string = "## Alpha"
		textView.setSelectedRange(NSRange(location: 3, length: 5))

		_ = textView.performKeyEquivalent(with: keyEvent("-", modifiers: [.command]))
		#expect(textView.string == "## Alpha", "⌘− must remain available to Decrease Font Size")

		_ = textView.performKeyEquivalent(with: keyEvent("=", modifiers: [.command, .shift]))
		#expect(textView.string == "## Alpha", "⌘+ must remain available to Increase Font Size")

		_ = textView.performKeyEquivalent(with: keyEvent("b", modifiers: [.command, .option]))
		#expect(textView.string == "## Alpha", "extra modifiers must not trigger Bold")

		#expect(textView.performKeyEquivalent(
			with: keyEvent("-", modifiers: [.command, .option])))
		#expect(textView.string == "### Alpha")
	}

	@Test func rawLinkCommandPlacesTheCaretInTheDestinationSlot() {
		let textView = MarkdownFormattingTextView(frame: .zero)
		textView.string = "Read Marker"
		textView.setSelectedRange((textView.string as NSString).range(of: "Marker"))
		textView.applyFormatting(.link)
		#expect(textView.string == "Read [Marker]()")
		#expect(textView.selectedRange() == NSRange(location: 14, length: 0))
	}

	private func keyEvent(_ characters: String, modifiers: NSEvent.ModifierFlags) -> NSEvent {
		NSEvent.keyEvent(
			with: .keyDown,
			location: .zero,
			modifierFlags: modifiers,
			timestamp: 0,
			windowNumber: 0,
			context: nil,
			characters: characters,
			charactersIgnoringModifiers: characters,
			isARepeat: false,
			keyCode: 0)!
	}
}
#endif
