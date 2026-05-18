//
//  MarkdownSyntaxHighlighter.swift
//  MarkDownRange
//

#if os(macOS)
import AppKit

enum MarkdownSyntaxHighlighter {
	static func highlight(textView: NSTextView, theme: MarkdownTheme, options: MarkdownOptions = .default) {
		guard let layoutManager = textView.layoutManager,
			  let textStorage = textView.textStorage else { return }
		let string = textView.string
		let fullRange = NSRange(location: 0, length: (string as NSString).length)
		guard fullRange.length > 0 else { return }

		let basePointSize = textView.font?.pointSize ?? 13
		let regularFont = NSFont.monospacedSystemFont(ofSize: basePointSize, weight: .regular)
		let headingFont = NSFont.monospacedSystemFont(ofSize: basePointSize, weight: .bold)

		// Font has to live in textStorage (it affects layout, so it's not a
		// valid NSLayoutManager temporary attribute key). Wrap in begin/end
		// to coalesce the per-range updates into a single layout pass.
		textStorage.beginEditing()
		textStorage.addAttribute(.font, value: regularFont, range: fullRange)

		layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)

		let codeFenceRanges = matches(for: codeFencePattern, in: string)
		apply(codeFenceRanges, color: theme.codeForeground, layoutManager: layoutManager)

		// Color and embolden the entire heading line so the source still
		// reads like a heading in the raw pane. Monospaced bold shares
		// metrics with monospaced regular, so line-wrap is unaffected.
		let lineRegex = headingLinePattern(for: options)
		let markerRegex = headingMarkerPattern(for: options)
		for range in matches(for: lineRegex, in: string) {
			guard !intersects(range, codeFenceRanges) else { continue }
			layoutManager.addTemporaryAttribute(.foregroundColor, value: NSColor(theme.headingColor), forCharacterRange: range)
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
			for range in matches(for: pattern, in: string) {
				guard !intersects(range, codeFenceRanges) else { continue }
				layoutManager.addTemporaryAttribute(.foregroundColor, value: NSColor(color), forCharacterRange: range)
			}
		}

		textStorage.endEditing()

		// The textStorage edits above invalidate layout for everything they
		// touched. Without forcing layout here, TextKit recomputes each
		// chunk lazily as it scrolls into view, producing a noticeable
		// per-screen pause for monospaced docs with bolded headings.
		layoutManager.ensureLayout(forCharacterRange: fullRange)
	}

	/// Clear any styling this highlighter added. Used when syntax highlighting
	/// is toggled off so the heading weight + colors don't linger.
	static func clearHighlighting(textView: NSTextView) {
		guard let layoutManager = textView.layoutManager,
			  let textStorage = textView.textStorage else { return }
		let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
		guard fullRange.length > 0 else { return }
		let regularFont = NSFont.monospacedSystemFont(ofSize: textView.font?.pointSize ?? 13, weight: .regular)
		textStorage.beginEditing()
		textStorage.addAttribute(.font, value: regularFont, range: fullRange)
		textStorage.endEditing()
		layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
		layoutManager.ensureLayout(forCharacterRange: fullRange)
	}

	private static func apply(_ ranges: [NSRange], color: Color, layoutManager: NSLayoutManager) {
		let nsColor = NSColor(color)
		for range in ranges {
			layoutManager.addTemporaryAttribute(.foregroundColor, value: nsColor, forCharacterRange: range)
		}
	}

	private static func matches(for regex: NSRegularExpression, in string: String) -> [NSRange] {
		let nsString = string as NSString
		return regex.matches(in: string, range: NSRange(location: 0, length: nsString.length)).map(\.range)
	}

	private static func intersects(_ range: NSRange, _ exclusions: [NSRange]) -> Bool {
		exclusions.contains { NSIntersectionRange($0, range).length > 0 }
	}

	// MARK: - Patterns

	private typealias Color = SwiftUI.Color

	nonisolated(unsafe) private static let codeFencePattern = try! NSRegularExpression(
		pattern: "^```[^\\n]*\\n[\\s\\S]*?^```", options: [.anchorsMatchLines])
	nonisolated(unsafe) private static let inlineCodePattern = try! NSRegularExpression(
		pattern: "`[^`\\n]+`")

	// Strict CommonMark: require a space after the final `#`.
	nonisolated(unsafe) private static let strictHeadingMarkerPattern = try! NSRegularExpression(
		pattern: "^#{1,6}\\s", options: .anchorsMatchLines)
	nonisolated(unsafe) private static let strictHeadingLinePattern = try! NSRegularExpression(
		pattern: "^#{1,6}\\s.*$", options: .anchorsMatchLines)
	// Lenient: 1–6 `#` followed by anything that isn't another `#`. The
	// negative lookahead `(?!#)` rules out `#######` runs (CommonMark caps
	// headings at six). The marker variant also greedily eats a trailing
	// space when present so `## Heading` still highlights `## ` as marker.
	nonisolated(unsafe) private static let lenientHeadingMarkerPattern = try! NSRegularExpression(
		pattern: "^#{1,6}(?!#)\\s?", options: .anchorsMatchLines)
	nonisolated(unsafe) private static let lenientHeadingLinePattern = try! NSRegularExpression(
		pattern: "^#{1,6}(?!#).*$", options: .anchorsMatchLines)

	private static func headingMarkerPattern(for options: MarkdownOptions) -> NSRegularExpression {
		options.headingsRequireSpaceAfterHash ? strictHeadingMarkerPattern : lenientHeadingMarkerPattern
	}

	private static func headingLinePattern(for options: MarkdownOptions) -> NSRegularExpression {
		options.headingsRequireSpaceAfterHash ? strictHeadingLinePattern : lenientHeadingLinePattern
	}
	nonisolated(unsafe) private static let boldPattern = try! NSRegularExpression(
		pattern: "(\\*\\*|__)(.*?)(\\1)")
	nonisolated(unsafe) private static let italicPattern = try! NSRegularExpression(
		pattern: "(?<![*_])([*_])(?![*_])(.+?)(?<![*_])\\1(?![*_])")
	nonisolated(unsafe) private static let linkBracketsPattern = try! NSRegularExpression(
		pattern: "\\[([^\\]]+)\\]\\(")
	nonisolated(unsafe) private static let linkURLPattern = try! NSRegularExpression(
		pattern: "\\]\\(([^)]+)\\)")
	nonisolated(unsafe) private static let blockquotePattern = try! NSRegularExpression(
		pattern: "^>\\s?.*$", options: .anchorsMatchLines)
	nonisolated(unsafe) private static let listMarkerPattern = try! NSRegularExpression(
		pattern: "^\\s*([-*+]|\\d+\\.)\\s", options: .anchorsMatchLines)
	nonisolated(unsafe) private static let hrPattern = try! NSRegularExpression(
		pattern: "^(---+|\\*\\*\\*+|___+)$", options: .anchorsMatchLines)
}
#endif
