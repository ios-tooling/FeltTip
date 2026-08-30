//
//  MarkdownInlineCodeToggleTests.swift
//  MarkDownRangeTests
//

import Foundation
import Testing
@testable import MarkDownRange

#if os(macOS)
#if os(macOS)
	import AppKit
#else
	import UIKit
#endif
#endif

@Suite @MainActor struct MarkdownInlineCodeToggleTests {
	private func applying(_ change: MarkdownInlineCodeToggle.Change, to source: String) -> String {
		(source as NSString).replacingCharacters(in: change.range, with: change.replacement)
	}

	@Test func wrapsAndUnwrapsAPlainSelection() throws {
		let source = "Use TimelineEntryWidget here"
		let selection = (source as NSString).range(of: "TimelineEntryWidget")
		let wrapped = try #require(MarkdownInlineCodeToggle.change(in: source, selection: selection))
		let coded = applying(wrapped, to: source)
		#expect(coded == "Use `TimelineEntryWidget` here")
		#expect(wrapped.selection == NSRange(location: selection.location + 1, length: selection.length))

		let unwrapped = try #require(MarkdownInlineCodeToggle.change(in: coded, selection: wrapped.selection))
		#expect(applying(unwrapped, to: coded) == source)
		#expect(unwrapped.selection == selection)
	}

	@Test func choosesAPaddedDelimiterWhenTheSelectionContainsBackticks() throws {
		let source = "Use `literal` characters"
		let selection = (source as NSString).range(of: "`literal`")
		let wrapped = try #require(MarkdownInlineCodeToggle.change(in: source, selection: selection))
		let coded = applying(wrapped, to: source)
		#expect(coded == "Use `` `literal` `` characters")

		let unwrapped = try #require(MarkdownInlineCodeToggle.change(in: coded, selection: wrapped.selection))
		#expect(applying(unwrapped, to: coded) == source)
	}

	@Test func collapsedSelectionInsertsAnEmptyCodeSpan() throws {
		let source = "Use here"
		let selection = NSRange(location: 4, length: 0)
		let change = try #require(MarkdownInlineCodeToggle.change(in: source, selection: selection))
		#expect(applying(change, to: source) == "Use ``here")
		#expect(change.selection == NSRange(location: 5, length: 0))
	}

	@Test(arguments: [
		(source: "`Bravo charlie`", selected: "Bravo", expected: "Bravo `charlie`"),
		(source: "`Bravo charlie`", selected: "charlie", expected: "`Bravo` charlie"),
		(source: "`Alpha Bravo charlie`", selected: "Bravo",
		 expected: "`Alpha` Bravo `charlie`"),
		(source: "`Alpha` Bravo `charlie`", selected: "Bravo",
		 expected: "`Alpha` `Bravo` `charlie`"),
		(source: "`` `Alpha` Bravo charlie ``", selected: "Bravo",
		 expected: "`` `Alpha` `` Bravo `charlie`"),
	])
	func partialSelectionsSplitTheCodeSpan(
		source: String,
		selected: String,
		expected: String
	) throws {
		let selection = (source as NSString).range(of: selected)
		let change = try #require(
			MarkdownInlineCodeToggle.change(in: source, selection: selection))
		let result = applying(change, to: source)
		#expect(result == expected)
		#expect((result as NSString).substring(with: change.selection) == selected)
	}

	#if os(macOS)
	@Test func rawEditorCommandRoundTripsTheSelection() {
		let textView = MarkdownFormattingTextView(frame: .zero)
		textView.string = "Use TimelineEntryWidget here"
		textView.setSelectedRange((textView.string as NSString).range(of: "TimelineEntryWidget"))

		textView.toggleCode()
		#expect(textView.string == "Use `TimelineEntryWidget` here")
		#expect((textView.string as NSString).substring(with: textView.selectedRange()) == "TimelineEntryWidget")

		textView.toggleCode()
		#expect(textView.string == "Use TimelineEntryWidget here")
		#expect((textView.string as NSString).substring(with: textView.selectedRange()) == "TimelineEntryWidget")
	}
	#endif
}
