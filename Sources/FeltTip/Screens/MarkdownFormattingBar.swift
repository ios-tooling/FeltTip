//
//  MarkdownFormattingBar.swift
//  FeltTip
//
//  The formatting row that sits above the keyboard while the styled view is
//  being edited on iOS. macOS reaches these same commands through the Format
//  menu; iOS has no menu bar, and dismissing the keyboard to reach a toolbar
//  menu for every bold makes the styled editor much less useful on a phone.
//
//  Every button goes through the host's `applyFormatting`, so the edit takes
//  the ordinary verified route into the markdown source — this is a new way to
//  ask, not a new way to mutate.
//

#if os(iOS)
import SwiftUI

struct MarkdownFormattingBar: View {
	let apply: (MarkdownFormattingCommand) -> Void
	let insertListItem: () -> Void

	/// Ordered by how often they're reached for, since the row scrolls and
	/// only the first few are visible without a swipe.
	private static let items: [(command: MarkdownFormattingCommand, symbol: String, label: String)] = [
		(.bold, "bold", "Bold"),
		(.italic, "italic", "Italic"),
		(.inlineCode, "chevron.left.forwardslash.chevron.right", "Code"),
		(.link, "link", "Link"),
		(.increaseHeading, "textformat.size.larger", "Bigger Heading"),
		(.decreaseHeading, "textformat.size.smaller", "Smaller Heading"),
		(.bulletedList, "list.bullet", "Bulleted List"),
		(.numberedList, "list.number", "Numbered List"),
		(.taskList, "checklist", "Task List"),
		(.blockQuote, "text.quote", "Quote"),
		(.strikethrough, "strikethrough", "Strikethrough"),
		(.highlight, "highlighter", "Highlight"),
	]

	var body: some View {
		ScrollView(.horizontal) {
			HStack(spacing: 4) {
				ForEach(Self.items, id: \.command) { item in
					FormattingBarButton(symbol: item.symbol, label: item.label) {
						apply(item.command)
					}
				}
				Divider().frame(height: 22)
				FormattingBarButton(symbol: "return", label: "New List Item", action: insertListItem)
			}
			.padding(.horizontal, 8)
		}
		.scrollIndicators(.hidden)
		.frame(height: 44)
		.background(.bar)
	}
}

private struct FormattingBarButton: View {
	let symbol: String
	let label: String
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			Image(systemName: symbol)
				.frame(width: 40, height: 36)
				.contentShape(.rect)
		}
		.buttonStyle(.plain)
		.accessibilityLabel(label)
	}
}
#endif
