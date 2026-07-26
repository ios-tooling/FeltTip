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
		guard mods.contains(.command), !mods.contains(.option), !mods.contains(.control) else {
			return super.performKeyEquivalent(with: event)
		}

		switch event.charactersIgnoringModifiers ?? "" {
		case "b": toggleInlineFormat("**"); return true
		case "i": toggleInlineFormat("_"); return true
		case "k": insertLinkFormat(); return true
		case "=": adjustHeading(promote: true); return true
		case "-" where !mods.contains(.shift): adjustHeading(promote: false); return true
		case "6" where mods.contains(.shift): toggleInlineFormat("^"); return true
		case "-" where mods.contains(.shift): toggleInlineFormat("~"); return true
		case "x" where mods.contains(.shift), "X" where mods.contains(.shift):
			toggleInlineFormat("~~"); return true
		case "\r", "\u{3}": return false
		default: return super.performKeyEquivalent(with: event)
		}
	}

	/// Menu-item entry points, matching the key equivalents above.
	public func toggleBold() { toggleInlineFormat("**") }
	public func toggleItalic() { toggleInlineFormat("_") }
	public func toggleStrikethrough() { toggleInlineFormat("~~") }
	public func toggleCode() {
		guard let change = MarkdownInlineCodeToggle.change(in: string, selection: selectedRange()) else { return }
		applyChange(in: change.range, with: change.replacement, cursor: change.selection)
	}

	private func toggleInlineFormat(_ marker: String) {
		let sel = selectedRange()
		let ns = string as NSString
		let selected = ns.substring(with: sel)
		let len = (marker as NSString).length

		let preStart = max(0, sel.location - len)
		let postEnd = min(ns.length, NSMaxRange(sel) + len)
		let pre = ns.substring(with: NSRange(location: preStart, length: sel.location - preStart))
		let post = ns.substring(with: NSRange(location: NSMaxRange(sel), length: postEnd - NSMaxRange(sel)))

		if pre == marker && post == marker {
			let fullRange = NSRange(location: preStart, length: len + sel.length + len)
			applyChange(in: fullRange, with: selected, cursor: NSRange(location: preStart, length: (selected as NSString).length))
		} else if selected.isEmpty {
			applyChange(in: sel, with: marker + marker, cursor: NSRange(location: sel.location + len, length: 0))
		} else {
			let wrapped = marker + selected + marker
			applyChange(in: sel, with: wrapped, cursor: NSRange(location: sel.location + len, length: (selected as NSString).length))
		}
	}

	private func insertLinkFormat() {
		let sel = selectedRange()
		let selected = (string as NSString).substring(with: sel)
		let newText = "[\(selected)]()"
		let cursorPos = sel.location + (selected as NSString).length + 3
		applyChange(in: sel, with: newText, cursor: NSRange(location: cursorPos, length: 0))
	}

	private func adjustHeading(promote: Bool) {
		let loc = selectedRange().location
		let lineRange = (string as NSString).lineRange(for: NSRange(location: loc, length: 0))
		var line = (string as NSString).substring(with: lineRange)
		let hasNewline = line.hasSuffix("\n")
		if hasNewline { line = String(line.dropLast()) }

		var level = 0
		for ch in line { if ch == "#" { level += 1 } else { break } }
		if level > 0 {
			let idx = line.index(line.startIndex, offsetBy: level)
			if idx >= line.endIndex || line[idx] != " " { level = 0 }
		}

		let content = level > 0 ? String(line.dropFirst(level + 1)) : line
		let newLevel: Int
		if promote {
			newLevel = level == 0 ? 1 : max(1, level - 1)
		} else {
			newLevel = level == 0 ? 0 : level >= 6 ? 0 : level + 1
		}

		let newLine = newLevel == 0 ? content : String(repeating: "#", count: newLevel) + " " + content
		let range = NSRange(location: lineRange.location, length: (line as NSString).length)
		applyChange(in: range, with: newLine, cursor: NSRange(location: lineRange.location + (newLine as NSString).length, length: 0))
	}

	private func applyChange(in range: NSRange, with text: String, cursor: NSRange) {
		guard shouldChangeText(in: range, replacementString: text) else { return }
		textStorage?.replaceCharacters(in: range, with: text)
		didChangeText()
		setSelectedRange(cursor)
	}
}
#endif
