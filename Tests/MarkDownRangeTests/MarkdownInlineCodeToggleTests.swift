//
//  MarkdownInlineCodeToggleTests.swift
//  MarkDownRangeTests
//

import Foundation
import Testing
@testable import MarkDownRange

#if os(macOS)
import AppKit
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
