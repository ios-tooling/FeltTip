//
//  InlineContent.swift
//  FeltTip
//
//  The parsed inline content of a paragraph, heading, or table cell: a flat
//  list of styled text runs. Every consumer reads this back run by run (the
//  HTML renderer emits spans, the native preview builds NSAttributedString
//  attributes, the memo shifts stamps), so the model stores exactly those
//  facts instead of boxing them into an `AttributedString`, whose rope and
//  attribute machinery dominated parse time on inline-heavy documents.
//

import Foundation
import SwiftUI

/// Inline formatting flags. Colors follow from these at render time
/// (links, code, highlights, and dimmed placeholders) together with the
/// theme, so no run carries a color of its own.
public struct InlineStyle: OptionSet, Hashable, Sendable {
	public let rawValue: UInt16
	public init(rawValue: UInt16) { self.rawValue = rawValue }

	public static let bold = InlineStyle(rawValue: 1 << 0)
	public static let italic = InlineStyle(rawValue: 1 << 1)
	public static let monospaced = InlineStyle(rawValue: 1 << 2)
	public static let underline = InlineStyle(rawValue: 1 << 3)
	public static let strikethrough = InlineStyle(rawValue: 1 << 4)
	public static let superscript = InlineStyle(rawValue: 1 << 5)
	public static let `subscript` = InlineStyle(rawValue: 1 << 6)
	public static let highlight = InlineStyle(rawValue: 1 << 7)
	/// Dimmed placeholder text, such as an image's alt text in running text.
	public static let secondary = InlineStyle(rawValue: 1 << 8)

	/// A run marked both ways renders as subscript; the flags mirror open
	/// tags, and the later one wins as it always has.
	public var isSuperscript: Bool { contains(.superscript) && !contains(.subscript) }

	public var fontTraits: InlineFontTraits {
		var traits: InlineFontTraits = []
		if contains(.bold) { traits.insert(.bold) }
		if contains(.italic) { traits.insert(.italic) }
		if contains(.monospaced) { traits.insert(.monospaced) }
		return traits
	}
}

public struct InlineRun: Hashable, Sendable {
	public var text: String
	public var style: InlineStyle
	public var link: URL?
	/// Hover text, from `<abbr title="…">`.
	public var toolTip: String?
	/// UTF-16 offset of the run's first character in the Markdown source,
	/// when the rendered text is a verbatim slice of it.
	public var markdownSourceOffset: Int?
	/// Source offset of the backslash before an escaped table pipe that this
	/// run renders as a plain `|`.
	public var markdownEscapedPipeSourceOffset: Int?

	public init(
		_ text: String, style: InlineStyle = [], link: URL? = nil, toolTip: String? = nil,
		markdownSourceOffset: Int? = nil, markdownEscapedPipeSourceOffset: Int? = nil
	) {
		self.text = text
		self.style = style
		self.link = link
		self.toolTip = toolTip
		self.markdownSourceOffset = markdownSourceOffset
		self.markdownEscapedPipeSourceOffset = markdownEscapedPipeSourceOffset
	}

	public var inlineFontTraits: InlineFontTraits { style.fontTraits }

	/// Equal in everything but text.
	public func sameAttributes(as other: InlineRun) -> Bool {
		style == other.style && link == other.link && toolTip == other.toolTip
			&& markdownSourceOffset == other.markdownSourceOffset
			&& markdownEscapedPipeSourceOffset == other.markdownEscapedPipeSourceOffset
	}
}

public struct InlineContent: Hashable, Sendable {
	public var runs: [InlineRun]

	public init(runs: [InlineRun] = []) { self.runs = runs }
	public init(_ text: String, style: InlineStyle = []) {
		runs = text.isEmpty ? [] : [InlineRun(text, style: style)]
	}

	/// The rendered plain text.
	public var characters: String {
		switch runs.count {
		case 0: return ""
		case 1: return runs[0].text
		default:
			var text = ""
			text.reserveCapacity(runs.reduce(0) { $0 + $1.text.utf8.count })
			for run in runs { text += run.text }
			return text
		}
	}

	public var isEmpty: Bool { runs.allSatisfy { $0.text.isEmpty } }

	/// Grapheme count of the rendered text, matching `characters.count`.
	public var characterCount: Int { runs.reduce(0) { $0 + $1.text.count } }

	/// Appends a run, dropping empty text so run indices always address
	/// visible content. Builders record run indices while they work, so
	/// neighbours are only merged by `coalesce()` once a build is complete.
	public mutating func append(_ run: InlineRun) {
		guard !run.text.isEmpty else { return }
		runs.append(run)
	}

	public static func += (lhs: inout InlineContent, rhs: InlineContent) {
		lhs.runs.append(contentsOf: rhs.runs)
	}

	public static func + (lhs: InlineContent, rhs: InlineContent) -> InlineContent {
		InlineContent(runs: lhs.runs + rhs.runs)
	}

	/// Makes runs canonical: neighbours whose formatting and stamps are
	/// equal become one run, so equal content has equal runs.
	public mutating func coalesce() {
		coalesce(after: 0)
	}

	/// Merges identical neighbours among the runs from `index` on, never
	/// across that boundary, so indices recorded before it stay valid.
	private mutating func coalesce(after index: Int) {
		var i = index + 1
		while i < runs.count {
			if runs[i - 1].sameAttributes(as: runs[i]) {
				runs[i - 1].text += runs[i].text
				runs.remove(at: i)
			} else {
				i += 1
			}
		}
	}

	/// Links every run from `index` on; a link's label is whatever its
	/// children produced. A placeholder in a link takes the link's color.
	public mutating func setLink(_ url: URL, fromRun index: Int) {
		guard index < runs.count else { return }
		for i in index..<runs.count {
			runs[i].link = url
			runs[i].style.remove(.secondary)
		}
		coalesce(after: index)
	}

	/// Links the runs covering a grapheme range, splitting runs at its ends.
	/// Returns false, leaving the content unchanged, when the range already
	/// carries a link or touches verbatim code or `<kbd>` text, where neither
	/// Markdown's inline rules nor GFM autolinking apply.
	@discardableResult
	public mutating func applyLink(_ url: URL, characterRange range: Range<Int>) -> Bool {
		guard !range.isEmpty else { return false }
		var position = 0
		var first: Int?
		var last: Int?
		for (index, run) in runs.enumerated() {
			let end = position + run.text.count
			defer { position = end }
			guard end > range.lowerBound, position < range.upperBound else { continue }
			if run.link != nil || run.style.contains(.monospaced) { return false }
			if first == nil { first = index }
			last = index
		}
		guard let first, let last else { return false }
		// Split the boundary runs so the link covers exactly the range. A
		// trailing fragment's stamp advances past the text its predecessor
		// kept, so every stamp still addresses the fragment's own start.
		var rebuilt: [InlineRun] = []
		rebuilt.reserveCapacity(runs.count + 2)
		position = 0
		for (index, run) in runs.enumerated() {
			let end = position + run.text.count
			defer { position = end }
			guard index >= first, index <= last else { rebuilt.append(run); continue }
			let lower = max(range.lowerBound, position) - position
			let upper = min(range.upperBound, end) - position
			let text = run.text
			let lowerIndex = text.index(text.startIndex, offsetBy: lower)
			let upperIndex = text.index(lowerIndex, offsetBy: upper - lower)
			func fragment(_ slice: Substring, stamp: Int?, linked: Bool) -> InlineRun {
				var piece = run
				piece.text = String(slice)
				piece.markdownSourceOffset = stamp
				if linked {
					piece.link = url
					piece.style.remove(.secondary)
				}
				return piece
			}
			let stamp = run.markdownSourceOffset
			if lower > 0 { rebuilt.append(fragment(text[..<lowerIndex], stamp: stamp, linked: false)) }
			rebuilt.append(fragment(
				text[lowerIndex..<upperIndex],
				stamp: stamp.map { $0 + text[..<lowerIndex].utf16.count }, linked: true))
			if upperIndex < text.endIndex {
				rebuilt.append(fragment(text[upperIndex...], stamp: stamp.map { $0 + text[..<upperIndex].utf16.count }, linked: false))
			}
		}
		runs = rebuilt
		coalesce(after: first)
		return true
	}

	/// Drops the first `count` graphemes. A run that loses a prefix keeps its
	/// stamp pointing at its own first remaining character.
	public mutating func removeFirst(characters count: Int) {
		var remaining = count
		var index = 0
		while remaining > 0, index < runs.count {
			let length = runs[index].text.count
			if length <= remaining {
				remaining -= length
				index += 1
				continue
			}
			let text = runs[index].text
			let cut = text.index(text.startIndex, offsetBy: remaining)
			if let stamp = runs[index].markdownSourceOffset {
				runs[index].markdownSourceOffset = stamp + text[..<cut].utf16.count
			}
			runs[index].text = String(text[cut...])
			remaining = 0
		}
		runs.removeFirst(index)
		coalesce()
	}

	/// The content with every source stamp moved by `delta`.
	public func shiftingStamps(by delta: Int) -> InlineContent {
		guard delta != 0 else { return self }
		var shifted = self
		for index in shifted.runs.indices {
			if let offset = shifted.runs[index].markdownSourceOffset {
				shifted.runs[index].markdownSourceOffset = offset + delta
			}
			if let pipe = shifted.runs[index].markdownEscapedPipeSourceOffset {
				shifted.runs[index].markdownEscapedPipeSourceOffset = pipe + delta
			}
		}
		return shifted
	}

	/// An `AttributedString` carrying the same formatting, for hosts that
	/// display inline content with SwiftUI text. Fonts, colors, and the
	/// FeltTip attributes (`inlineFontTraits`, `markdownSourceOffset`) are
	/// filled in the way the parser once did directly.
	public func attributedString(theme: MarkdownTheme, fontSize: CGFloat) -> AttributedString {
		var result = AttributedString()
		for run in runs {
			var container = AttributeContainer()
			let style = run.style
			if style.contains(.monospaced) {
				container.font = .system(size: fontSize, design: .monospaced)
				container.foregroundColor = theme.codeForeground
				container.backgroundColor = theme.codeBackground
			} else {
				var font = Font.system(size: style.contains(.superscript) || style.contains(.subscript) ? fontSize * 0.75 : fontSize)
				if style.contains(.bold) { font = font.bold() }
				if style.contains(.italic) { font = font.italic() }
				container.font = font
			}
			if style.contains(.underline) { container.underlineStyle = .single }
			if style.contains(.strikethrough) { container.strikethroughStyle = .single }
			if style.isSuperscript { container.baselineOffset = fontSize * 0.3 }
			if style.contains(.subscript) { container.baselineOffset = -(fontSize * 0.2) }
			if style.contains(.highlight) { container.backgroundColor = .yellow.opacity(0.3) }
			if style.contains(.secondary) { container.foregroundColor = theme.secondaryColor }
			let traits = style.fontTraits
			if !traits.isEmpty { container.inlineFontTraits = traits }
			if let link = run.link {
				container.link = link
				container.foregroundColor = theme.linkColor
			}
			#if canImport(AppKit)
			if let toolTip = run.toolTip { container.toolTip = toolTip }
			#endif
			if let offset = run.markdownSourceOffset { container.markdownSourceOffset = offset }
			if let pipe = run.markdownEscapedPipeSourceOffset { container.markdownEscapedPipeSourceOffset = pipe }
			result += AttributedString(run.text, attributes: container)
		}
		return result
	}
}
