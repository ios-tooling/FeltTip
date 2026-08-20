//
//  MarkdownWebViewFindHost+Formatting.swift
//  MarkDownRange
//
//  Formatting entry points for the styled view, shared by both platforms.
//  macOS drives these from the Format menu; iOS from the keyboard accessory
//  bar. Either way they reach the markdown source through the edit bridge's
//  format-command path, with the same verification and caret restoration as a
//  keystroke — they are not a separate mutation route.
//
//  The two hosts are different classes (an NSView and a UIView) that share a
//  name and a `webView`, so one extension covers both.
//

import WebKit

public extension MarkdownWebViewFindHost {
	/// WebKit's own editor commands, which the page observes as `beforeinput`
	/// and routes like any other styled edit.
	func toggleBold() {
		webView.evaluateJavaScript("document.execCommand('bold')", completionHandler: nil)
	}

	func toggleItalic() {
		webView.evaluateJavaScript("document.execCommand('italic')", completionHandler: nil)
	}

	func toggleStrikethrough() {
		webView.evaluateJavaScript("document.execCommand('strikeThrough')", completionHandler: nil)
	}

	func toggleCode() {
		applyFormatting(.inlineCode)
	}

	func applyFormatting(_ command: MarkdownFormattingCommand) {
		webView.evaluateJavaScript(
			"window.__mdApplyFormat && window.__mdApplyFormat('\(command.rawValue)')",
			completionHandler: nil)
	}

	/// Append to the list containing the styled insertion point, or the first
	/// visible list when no list owns the selection. The page routes this
	/// through its ordinary structural Return path, including source
	/// verification and caret restoration.
	func insertListItem() {
		webView.evaluateJavaScript(
			"window.__mdInsertListItem && window.__mdInsertListItem()",
			completionHandler: nil)
	}
}
