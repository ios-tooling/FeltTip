//
//  MarkdownSyntaxHighlighter.swift
//  MarkDownRange
//

import CrossPlatformKit
#if os(macOS)
	import AppKit
#else
	import UIKit
#endif

enum MarkdownSyntaxHighlighter {
	/// Apply (or refresh) syntax styling for the editor.
	///
	/// `editedRange` is a hint about which part of the document changed. When
	/// supplied, we expand it to paragraph boundaries and re-process only that
	/// scope, leaving the rest of the document's attributes untouched. This is
	/// the per-keystroke fast path — on a long document the win is roughly
	/// O(N) → O(paragraph). When the affected range straddles a code-fence
	/// boundary the meaning of distant text could change, so we transparently
	/// fall back to a full-document highlight.
	@MainActor static func highlight(
		textView: UXTextView,
		theme: MarkdownTheme,
		options: MarkdownOptions = .default,
		editedRange: NSRange? = nil,
		codeFenceRanges cachedFenceRanges: [NSRange]? = nil
	) {
		guard let sink = textView.highlightSink,
			  let textStorage = textView.uxTextStorage else { return }
		let string = textView.sourceString
		let nsString = string as NSString
		let fullRange = NSRange(location: 0, length: nsString.length)
		guard fullRange.length > 0 else { return }

		let scope = highlightScope(for: editedRange, in: nsString, string: string, fullRange: fullRange)

		let basePointSize = textView.font?.pointSize ?? 13
		let regularFont = UXFont.monospacedSystemFont(ofSize: basePointSize, weight: .regular)
		let headingFont = UXFont.monospacedSystemFont(ofSize: basePointSize, weight: .bold)

		// Font has to live in textStorage (it affects layout, so it's not a
		// valid NSLayoutManager temporary attribute key). Wrap in begin/end
		// to coalesce the per-range updates into a single layout pass.
		textStorage.beginEditing()
		textStorage.addAttribute(.font, value: regularFont, range: scope)
		sink.resetColor(in: scope, base: UXColor(theme.textColor))

		// Code fences must always be scanned over the whole document because a
		// fence may begin outside `scope` but reach into it.
		let codeFenceRanges = cachedFenceRanges ?? fenceRanges(in: string)
		for fence in codeFenceRanges {
			let inter = NSIntersectionRange(fence, scope)
			if inter.length > 0 {
				sink.setColor(UXColor(theme.codeForeground), in: inter)
			}
		}

		// Color and embolden the entire heading line so the source still
		// reads like a heading in the raw pane. Monospaced bold shares
		// metrics with monospaced regular, so line-wrap is unaffected.
		let lineRegex = headingLinePattern(for: options)
		let markerRegex = headingMarkerPattern(for: options)
		for range in matches(for: lineRegex, in: string, in: scope) {
			guard !intersects(range, codeFenceRanges) else { continue }
			sink.setColor(UXColor(theme.headingColor), in: range)
			textStorage.addAttribute(.font, value: headingFont, range: range)
		}

		let patterns: [(NSRegularExpression, Color)] = [
			(markerRegex, theme.secondaryColor),
			(boldPattern, theme.secondaryColor),
			(italicPattern, theme.secondaryColor),
			(inlineCodePattern, theme.codeForeground),
			(linkBracketsPattern, theme.secondaryColor),
			(linkURLPattern, theme.linkColor),
			(blockquotePattern, theme.secondaryColor),
			(listMarkerPattern, theme.secondaryColor),
			(hrPattern, theme.secondaryColor),
		]

		for (pattern, color) in patterns {
			for range in matches(for: pattern, in: string, in: scope) {
				guard !intersects(range, codeFenceRanges) else { continue }
				sink.setColor(UXColor(color), in: range)
			}
		}

		textStorage.endEditing()
		// Skip the full-document `ensureLayout` here. It was added to avoid
		// per-screen layout pauses while scrolling, but running it on every
		// keystroke forces TextKit to lay out the entire document up-front
		// each time and is the single biggest source of typing latency.
		// TextKit lays out lazily as content scrolls into view, which is the
		// right trade-off for the edit hot path.
	}

	/// Clear any styling this highlighter added. Used when syntax highlighting
	/// is toggled off so the heading weight + colors don't linger.
	@MainActor static func clearHighlighting(textView: UXTextView, theme: MarkdownTheme? = nil) {
		guard let sink = textView.highlightSink,
			  let textStorage = textView.uxTextStorage else { return }
		let fullRange = NSRange(location: 0, length: (textView.sourceString as NSString).length)
		guard fullRange.length > 0 else { return }
		let regularFont = UXFont.monospacedSystemFont(ofSize: textView.font?.pointSize ?? 13, weight: .regular)
		textStorage.beginEditing()
		textStorage.addAttribute(.font, value: regularFont, range: fullRange)
		textStorage.endEditing()
		sink.resetColor(in: fullRange, base: UXColor(theme?.textColor ?? .primary))
	}

	// MARK: - Scope selection

	/// Decide which range to re-highlight: the full document, or just the
	/// paragraph(s) around the edit. We bail to full-doc whenever a triple
	/// backtick is anywhere in the expanded probe window, because flipping a
	/// code fence open or closed redefines the meaning of distant text.
	private static func highlightScope(
		for editedRange: NSRange?,
		in nsString: NSString,
		string: String,
		fullRange: NSRange
	) -> NSRange {
		guard let edited = editedRange,
			  edited.location <= nsString.length,
			  fullRange.length > 0
		else { return fullRange }

		let safeLength = max(0, min(edited.length, nsString.length - edited.location))
		let safeEdit = NSRange(location: edited.location, length: safeLength)
		let paragraphRange = nsString.paragraphRange(for: safeEdit)

		// Expand one line on either side so a fence opener adjacent to the
		// edit still triggers the full-doc fallback.
		let probe = expandToLineBoundaries(paragraphRange, in: nsString)
		let probeText = nsString.substring(with: probe)
		if probeText.contains("```") {
			return fullRange
		}
		return paragraphRange
	}

	private static func expandToLineBoundaries(_ range: NSRange, in nsString: NSString) -> NSRange {
		var start = range.location
		var end = range.location + range.length
		while start > 0, nsString.character(at: start - 1) != unichar(0x0A) { start -= 1 }
		if start > 0 { start -= 1 }
		while end < nsString.length, nsString.character(at: end) != unichar(0x0A) { end += 1 }
		if end < nsString.length { end += 1 }
		return NSRange(location: start, length: end - start)
	}

	private static func apply(_ ranges: [NSRange], color: Color, sink: MarkdownHighlightSink) {
		let uxColor = UXColor(color)
		for range in ranges {
			sink.setColor(uxColor, in: range)
		}
	}

	private static func matches(for regex: NSRegularExpression, in string: String) -> [NSRange] {
		let nsString = string as NSString
		return regex.matches(in: string, range: NSRange(location: 0, length: nsString.length)).map(\.range)
	}

	static func fenceRanges(in string: String) -> [NSRange] {
		let text = string as NSString
		let length = text.length
		guard length > 0 else { return [] }

		// A direct line walk is both more predictable than a whole-document
		// lazy regex and able to represent an unterminated fence. The latter
		// matters while the user is in the middle of typing a code block: from
		// the opener through EOF, Markdown syntax must remain suppressed.
		var ranges: [NSRange] = []
		var openFenceLocation: Int?
		var lineLocation = 0
		while lineLocation < length {
			let lineRange = text.lineRange(
				for: NSRange(location: lineLocation, length: 0))
			if lineRange.length >= 3,
			   text.character(at: lineLocation) == 0x60,
			   text.character(at: lineLocation + 1) == 0x60,
			   text.character(at: lineLocation + 2) == 0x60 {
				if let opener = openFenceLocation {
					// Match the previous behavior: the fenced range ends after
					// the closing marker, not after any trailing info text.
					ranges.append(NSRange(
						location: opener,
						length: lineLocation + 3 - opener))
					openFenceLocation = nil
				} else {
					openFenceLocation = lineLocation
				}
			}
			let nextLine = NSMaxRange(lineRange)
			guard nextLine > lineLocation else { break }
			lineLocation = nextLine
		}
		if let opener = openFenceLocation {
			ranges.append(NSRange(location: opener, length: length - opener))
		}
		return ranges
	}

	/// Range-scoped variant — only returns matches whose ranges sit entirely
	/// inside `searchRange`. Used by the incremental path so a regex doesn't
	/// have to scan the whole document for inline-only patterns.
	private static func matches(for regex: NSRegularExpression, in string: String, in searchRange: NSRange) -> [NSRange] {
		regex.matches(in: string, range: searchRange).map(\.range)
	}

	private static func intersects(_ range: NSRange, _ exclusions: [NSRange]) -> Bool {
		exclusions.contains { NSIntersectionRange($0, range).length > 0 }
	}

	// MARK: - Patterns

	private typealias Color = SwiftUI.Color

	private static let inlineCodePattern = try! NSRegularExpression(
		pattern: "`[^`\\n]+`")

	// Strict CommonMark: require a space after the final `#`.
	private static let strictHeadingMarkerPattern = try! NSRegularExpression(
		pattern: "^#{1,6}\\s", options: .anchorsMatchLines)
	private static let strictHeadingLinePattern = try! NSRegularExpression(
		pattern: "^#{1,6}\\s.*$", options: .anchorsMatchLines)
	// Lenient: 1–6 `#` followed by anything that isn't another `#`. The
	// negative lookahead `(?!#)` rules out `#######` runs (CommonMark caps
	// headings at six). The marker variant also greedily eats a trailing
	// space when present so `## Heading` still highlights `## ` as marker.
	private static let lenientHeadingMarkerPattern = try! NSRegularExpression(
		pattern: "^#{1,6}(?!#)\\s?", options: .anchorsMatchLines)
	private static let lenientHeadingLinePattern = try! NSRegularExpression(
		pattern: "^#{1,6}(?!#).*$", options: .anchorsMatchLines)

	private static func headingMarkerPattern(for options: MarkdownOptions) -> NSRegularExpression {
		options.headingsRequireSpaceAfterHash ? strictHeadingMarkerPattern : lenientHeadingMarkerPattern
	}

	private static func headingLinePattern(for options: MarkdownOptions) -> NSRegularExpression {
		options.headingsRequireSpaceAfterHash ? strictHeadingLinePattern : lenientHeadingLinePattern
	}
	private static let boldPattern = try! NSRegularExpression(
		pattern: "(\\*\\*|__)(.*?)(\\1)")
	private static let italicPattern = try! NSRegularExpression(
		pattern: "(?<![*_])([*_])(?![*_])(.+?)(?<![*_])\\1(?![*_])")
	private static let linkBracketsPattern = try! NSRegularExpression(
		pattern: "\\[([^\\]]+)\\]\\(")
	private static let linkURLPattern = try! NSRegularExpression(
		pattern: "\\]\\(([^)]+)\\)")
	private static let blockquotePattern = try! NSRegularExpression(
		pattern: "^>\\s?.*$", options: .anchorsMatchLines)
	private static let listMarkerPattern = try! NSRegularExpression(
		pattern: "^\\s*([-*+]|\\d+\\.)\\s", options: .anchorsMatchLines)
	private static let hrPattern = try! NSRegularExpression(
		pattern: "^(---+|\\*\\*\\*+|___+)$", options: .anchorsMatchLines)
}
