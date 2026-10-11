//
//  MarkdownSyntaxHighlighter.swift
//  FeltTip
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
	///
	/// `limitedTo` instead names an explicit scope (expanded to whole lines)
	/// with no fallback; the raw editor uses it to color only the window
	/// around the viewport of a large document. Code fences are still taken
	/// whole-document. `fonts` and `colors` select which half of the pass runs.
	@MainActor static func highlight(
		textView: UXTextView,
		theme: MarkdownTheme,
		options: MarkdownOptions = .default,
		editedRange: NSRange? = nil,
		limitedTo explicitScope: NSRange? = nil,
		fallbackScope: NSRange? = nil,
		codeFenceRanges cachedFenceRanges: [NSRange]? = nil,
		fonts: Bool = true,
		colors: Bool = true
	) {
		guard let sink = textView.highlightSink,
			  let textStorage = textView.uxTextStorage else { return }
		let string = textView.sourceString
		let nsString = string as NSString
		let fullRange = NSRange(location: 0, length: nsString.length)
		guard fullRange.length > 0 else { return }

		let scope: NSRange
		if let explicitScope {
			let clipped = NSIntersectionRange(explicitScope, fullRange)
			guard clipped.length > 0 || explicitScope.location == fullRange.length else { return }
			scope = nsString.lineRange(for: clipped)
		} else {
			// `fallbackScope` stands in for the whole document when an edit near
			// a fence would otherwise force a full pass (the raw editor passes
			// its colored window for large documents).
			let fallback = fallbackScope.map { NSIntersectionRange($0, fullRange) } ?? fullRange
			scope = highlightScope(for: editedRange, in: nsString, string: string, fullRange: fallback)
		}

		let basePointSize = textView.font?.pointSize ?? 13
		let regularFont = UXFont.monospacedSystemFont(ofSize: basePointSize, weight: .regular)
		let headingFont = UXFont.monospacedSystemFont(ofSize: basePointSize, weight: .bold)

		// Font has to live in textStorage (it affects layout, so it's not a
		// valid NSLayoutManager temporary attribute key). Wrap in begin/end
		// to coalesce the per-range updates into a single layout pass.
		textStorage.beginEditing()
		defer { textStorage.endEditing() }
		if colors { sink.resetColor(in: scope, base: UXColor(theme.textColor)) }

		// Colors are painted into a per-character buffer first, in the same pass
		// order as always (so later patterns still win where they overlap), and
		// only then written to the sink as runs in document order. Writing
		// overlay attributes pass by pass interleaves insertions all over the
		// document, and both TextKit attribute stores degrade badly under that:
		// 2 MB took ~6 s, against ~0.5 s for the same runs written in order.
		let palette: [UXColor] = [
			UXColor(markerColor(for: theme)),  // 1: markup
			UXColor(theme.linkColor),          // 2: link text and URL
		]
		let marker: UInt8 = 1, link: UInt8 = 2
		var paint = [UInt8](repeating: 0, count: scope.length)
		func fill(_ range: NSRange, _ color: UInt8) {
			let clipped = NSIntersectionRange(range, scope)
			guard clipped.length > 0 else { return }
			let start = clipped.location - scope.location
			for index in start..<(start + clipped.length) { paint[index] = color }
		}

		// Code fences must always be scanned over the whole document because a
		// fence may begin outside `scope` but reach into it. Only the fence
		// lines themselves are colored; the code inside keeps the body color.
		let codeFenceRanges = cachedFenceRanges ?? fenceRanges(in: string)
		let firstFence = firstIndex(endingAfter: scope.location, in: codeFenceRanges)
		for fence in codeFenceRanges[firstFence...] {
			guard fence.location < NSMaxRange(scope) else { break }
			for markerRange in fenceMarkerRanges(for: fence, in: nsString) {
				fill(markerRange, marker)
			}
		}

		// Embolden the entire heading line so the source still reads like a
		// heading in the raw pane; only the `#` marker gets color. Monospaced
		// bold shares metrics with monospaced regular, so line-wrap is unaffected.
		let lineRegex = headingLinePattern(for: options)
		let markerRegex = headingMarkerPattern(for: options)
		if fonts {
			let headings = matches(for: lineRegex, in: string, in: scope)
				.filter { !intersects($0, codeFenceRanges) }
			applyFonts(
				in: scope, bold: headings, regular: regularFont, heading: headingFont,
				to: textStorage)
		}
		guard colors else { return }

		// Color markup, not content: each pattern names the capture groups
		// holding its markers (0 = the whole match), all in the faded marker
		// color. Links are the exception —
		// their text and URL take the link color.
		let patterns: [(NSRegularExpression, [Int], UInt8)] = [
			(markerRegex, [0], marker),
			(boldPattern, [1, 3], marker),
			(italicPattern, [1, 3], marker),
			(inlineCodePattern, [1, 2], marker),
			(linkPattern, [1, 3, 5], marker),
			(linkPattern, [2, 4], link),
			(blockquotePattern, [0], marker),
			(listMarkerPattern, [0], marker),
			(hrPattern, [0], marker),
		]

		for (pattern, groups, color) in patterns {
			for match in pattern.matches(in: string, range: scope) {
				guard !intersects(match.range, codeFenceRanges) else { continue }
				for group in groups {
					let range = match.range(at: group)
					if range.location != NSNotFound, range.length > 0 {
						fill(range, color)
					}
				}
			}
		}

		var runStart = 0
		while runStart < paint.count {
			let color = paint[runStart]
			var runEnd = runStart + 1
			while runEnd < paint.count, paint[runEnd] == color { runEnd += 1 }
			if color != 0 {
				sink.setColor(
					palette[Int(color) - 1],
					in: NSRange(location: scope.location + runStart, length: runEnd - runStart))
			}
			runStart = runEnd
		}
		// Skip the full-document `ensureLayout` here. It was added to avoid
		// per-screen layout pauses while scrolling, but running it on every
		// keystroke forces TextKit to lay out the entire document up-front
		// each time and is the single biggest source of typing latency.
		// TextKit lays out lazily as content scrolls into view, which is the
		// right trade-off for the edit hot path.
	}

	/// Make `scope` regular except for the `bold` ranges, writing only where
	/// the stored font differs. Font attributes live in the text storage, and
	/// every storage write is an edit to TextKit: it invalidates layout, and on
	/// a TextKit 2 view of a very large document an edit can trigger layout of
	/// the whole document. Re-asserting fonts that are already right — every
	/// highlight pass did — was most of what made moving the colored window
	/// over a 20 MB document slow and destabilized its scroll position.
	static func applyFonts(
		in scope: NSRange, bold: [NSRange], regular: UXFont, heading: UXFont,
		to textStorage: NSTextStorage
	) {
		var location = scope.location
		func ensure(_ font: UXFont, _ range: NSRange) {
			guard range.length > 0 else { return }
			var effective = NSRange(location: NSNotFound, length: 0)
			let current = textStorage.attribute(
				.font, at: range.location, longestEffectiveRange: &effective, in: range) as? UXFont
			if current == font, NSEqualRanges(effective, range) { return }
			textStorage.addAttribute(.font, value: font, range: range)
		}
		for range in bold {
			let clipped = NSIntersectionRange(range, scope)
			guard clipped.length > 0, clipped.location >= location else { continue }
			ensure(regular, NSRange(location: location, length: clipped.location - location))
			ensure(heading, clipped)
			location = NSMaxRange(clipped)
		}
		ensure(regular, NSRange(location: location, length: NSMaxRange(scope) - location))
	}

	/// Index of the first sorted, non-overlapping range ending after `location`.
	private static func firstIndex(endingAfter location: Int, in ranges: [NSRange]) -> Int {
		var low = 0, high = ranges.count
		while low < high {
			let mid = (low + high) / 2
			if NSMaxRange(ranges[mid]) <= location { low = mid + 1 } else { high = mid }
		}
		return low
	}

	/// Clear any styling this highlighter added. Used when syntax highlighting
	/// is toggled off so the heading weight + colors don't linger.
	@MainActor static func clearHighlighting(textView: UXTextView, theme: MarkdownTheme? = nil) {
		guard let sink = textView.highlightSink,
			  let textStorage = textView.uxTextStorage else { return }
		let fullRange = NSRange(location: 0, length: (textView.sourceString as NSString).length)
		guard fullRange.length > 0 else { return }
		let size = textView.font?.pointSize ?? 13
		textStorage.beginEditing()
		applyFonts(
			in: fullRange, bold: [],
			regular: UXFont.monospacedSystemFont(ofSize: size, weight: .regular),
			heading: UXFont.monospacedSystemFont(ofSize: size, weight: .bold),
			to: textStorage)
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

	/// The opening fence line (including any info string) and, when the fence
	/// is closed, the closing backticks — the parts of a fence that are markup.
	static func fenceMarkerRanges(for fence: NSRange, in text: NSString) -> [NSRange] {
		var opener = text.lineRange(for: NSRange(location: fence.location, length: 0))
		while opener.length > 0, [0x0A, 0x0D].contains(text.character(at: NSMaxRange(opener) - 1)) { opener.length -= 1 }
		var ranges = [opener]
		let end = NSMaxRange(fence)
		if end - 3 > NSMaxRange(opener), text.character(at: end - 4) == 0x0A, text.substring(with: NSRange(location: end - 3, length: 3)) == "```" {
			ranges.append(NSRange(location: end - 3, length: 3))
		}
		return ranges
	}

	/// Range-scoped variant — only returns matches whose ranges sit entirely
	/// inside `searchRange`. Used by the incremental path so a regex doesn't
	/// have to scan the whole document for inline-only patterns.
	private static func matches(for regex: NSRegularExpression, in string: String, in searchRange: NSRange) -> [NSRange] {
		regex.matches(in: string, range: searchRange).map(\.range)
	}

	/// `exclusions` are fence ranges: sorted and non-overlapping, so binary
	/// search for the first one ending after `range` starts. A linear scan made
	/// full-document highlighting O(matches × fences) and froze large files.
	static func intersects(_ range: NSRange, _ exclusions: [NSRange]) -> Bool {
		var low = 0, high = exclusions.count
		while low < high {
			let mid = (low + high) / 2
			if NSMaxRange(exclusions[mid]) <= range.location { low = mid + 1 } else { high = mid }
		}
		return low < exclusions.count && NSIntersectionRange(exclusions[low], range).length > 0
	}

	/// Markup is drawn in a faded secondary color so it recedes behind the prose.
	static func markerColor(for theme: MarkdownTheme) -> SwiftUI.Color {
		theme.secondaryColor.opacity(0.45)
	}

	// MARK: - Patterns

	private typealias Color = SwiftUI.Color

	private static let inlineCodePattern = try! NSRegularExpression(
		pattern: "(`)[^`\\n]+(`)")

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
		pattern: "(?<![*_])([*_])(?![*_])(.+?)(?<![*_])(\\1)(?![*_])")
	// Groups: 1 `[`, 2 text, 3 `](`, 4 URL, 5 `)`.
	private static let linkPattern = try! NSRegularExpression(
		pattern: "(\\[)([^\\]]+)(\\]\\()([^)]+)(\\))")
	private static let blockquotePattern = try! NSRegularExpression(
		pattern: "^>\\s?", options: .anchorsMatchLines)
	private static let listMarkerPattern = try! NSRegularExpression(
		pattern: "^\\s*([-*+]|\\d+\\.)\\s", options: .anchorsMatchLines)
	private static let hrPattern = try! NSRegularExpression(
		pattern: "^(---+|\\*\\*\\*+|___+)$", options: .anchorsMatchLines)
}
