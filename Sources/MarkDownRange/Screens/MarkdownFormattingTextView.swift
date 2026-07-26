//
//  MarkdownFormattingTextView.swift
//  MarkdownRendering
//

#if os(macOS)
import AppKit

public class MarkdownFormattingTextView: NSTextView {

	override public func becomeFirstResponder() -> Bool {
		let accepted = super.becomeFirstResponder()
		if accepted, let coordinator = delegate as? MarkdownTextEditor.Coordinator {
			// Becoming the active pane: report the current selection right
			// away so the host clears this pane's now-stale mirror.
			coordinator.reportSelectionOnFocus(self)
		}
		return accepted
	}

	override public func performKeyEquivalent(with event: NSEvent) -> Bool {
		// Only when this editor is focused: performKeyEquivalent visits every
		// view in the window, and in a split the raw pane was consuming the
		// ⌘B/⌘I aimed at the styled pane, applying them to its own selection.
		guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
		let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
		switch (event.charactersIgnoringModifiers?.lowercased() ?? "", mods) {
		case ("b", [.command]): applyFormatting(.bold); return true
		case ("i", [.command]): applyFormatting(.italic); return true
		case ("u", [.command]): applyFormatting(.underline); return true
		case ("k", [.command]): applyFormatting(.link); return true
		case ("=", [.command, .option]): applyFormatting(.increaseHeading); return true
		case ("-", [.command, .option]): applyFormatting(.decreaseHeading); return true
		case ("6", [.command, .shift]): applyFormatting(.superscript); return true
		case ("-", [.command, .shift]): applyFormatting(.subscriptText); return true
		case ("x", [.command, .shift]):
			applyFormatting(.strikethrough); return true
		case ("\r", _), ("\u{3}", _): return false
		default: return super.performKeyEquivalent(with: event)
		}
	}

	/// Menu-item entry points, matching the key equivalents above.
	public func toggleBold() { applyFormatting(.bold) }
	public func toggleItalic() { applyFormatting(.italic) }
	public func toggleStrikethrough() { applyFormatting(.strikethrough) }
	public func toggleCode() { applyFormatting(.inlineCode) }

	public func applyFormatting(_ command: MarkdownFormattingCommand) {
		guard let change = MarkdownSourceFormatter.change(
			in: string,
			selection: selectedRange(),
			command: command) else { return }
		applyChange(
			in: change.range,
			with: change.replacement,
			cursor: change.rawSelection ?? change.selection)
	}

	private func applyChange(in range: NSRange, with text: String, cursor: NSRange) {
		guard shouldChangeText(in: range, replacementString: text) else { return }
		textStorage?.replaceCharacters(in: range, with: text)
		didChangeText()
		setSelectedRange(cursor)
	}
}
#endif
