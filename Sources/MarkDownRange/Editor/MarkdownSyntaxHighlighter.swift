//
//  MarkdownSyntaxHighlighter.swift
//  MarkDownRange
//

#if os(macOS)
import AppKit

enum MarkdownSyntaxHighlighter {
	static func highlight(textView: NSTextView, theme: MarkdownTheme) {
		guard let layoutManager = textView.layoutManager else { return }
		let string = textView.string
		let fullRange = NSRange(location: 0, length: (string as NSString).length)
		guard fullRange.length > 0 else { return }

		layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)

		let codeFenceRanges = matches(for: codeFencePattern, in: string)
		apply(codeFenceRanges, color: theme.codeForeground, layoutManager: layoutManager)

		let patterns: [(NSRegularExpression, Color)] = [
			(headingMarkerPattern, theme.secondaryColor),
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
	nonisolated(unsafe) private static let headingMarkerPattern = try! NSRegularExpression(
		pattern: "^#{1,6}\\s", options: .anchorsMatchLines)
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
