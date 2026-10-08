//
//  MarkdownHeading.swift
//  MarkdownRendering
//

import Foundation

public struct MarkdownHeading: Identifiable, Equatable, Sendable {
	public let id: String
	public let level: Int
	public let text: String
	/// UTF-16 source range of the complete heading line, matching NSTextView,
	/// NSRange, and the web edit bridge's offset units.
	public let sourceRange: NSRange

	public static func parse(from markdown: String) -> [MarkdownHeading] {
		var headings: [MarkdownHeading] = []
		let codeRanges = MarkdownCodeProtection.ranges(in: markdown, blocksOnly: true)
		var codeIndex = 0
		// Walk the source storage directly rather than materializing every line.
		// The supplied ranges also preserve exact UTF-16 locations for either
		// LF or CRLF line endings.
		markdown.enumerateSubstrings(
			in: markdown.startIndex..<markdown.endIndex,
			options: [.byLines, .substringNotRequired]
		) { _, lineRange, _, stop in
			if Task.isCancelled {
				stop = true
				return
			}
			let sourceRange = NSRange(lineRange, in: markdown)
			let trimmed = markdown[lineRange].trimmingCharacters(in: .whitespaces)

			while codeIndex < codeRanges.count, NSMaxRange(codeRanges[codeIndex]) <= sourceRange.location { codeIndex += 1 }
			if codeIndex < codeRanges.count, NSIntersectionRange(codeRanges[codeIndex], sourceRange).length > 0 { return }

			if let (level, text) = parseHeadingLine(trimmed) {
				let id = "\(headings.count)-\(text)"
				headings.append(MarkdownHeading(
					id: id, level: level, text: text,
					sourceRange: sourceRange))
			}
		}
		return headings
	}

	/// Fast heading line parser using string operations instead of regex.
	static func parseHeadingLine(_ trimmed: String) -> (level: Int, text: String)? {
		guard trimmed.hasPrefix("#") else { return nil }
		var level = 0
		for ch in trimmed {
			if ch == "#" { level += 1 } else { break }
		}
		guard level >= 1, level <= 6 else { return nil }
		let rest = trimmed.dropFirst(level)
		guard rest.first == " " || rest.first == "\t" else { return nil }
		let text = rest.drop(while: { $0 == " " || $0 == "\t" })
		guard !text.isEmpty else { return nil }
		return (level, String(text))
	}

	/// The heading at or before a UTF-16 offset, by a single line scan. This
	/// serves hot paths (scroll ticks, the window after an edit before the
	/// index refreshes) and must stay allocation-light; `parse` is the
	/// authoritative index. The scan tracks fences by character and length
	/// and skips indented code outside lists, so it agrees with `parse` for
	/// ordinary documents.
	public static func heading(atCharacterOffset offset: Int, in text: String) -> MarkdownHeading? {
		var last: MarkdownHeading?
		scanHeadings(in: text) { heading in
			guard heading.sourceRange.location <= offset else { return false }
			last = heading
			return true
		}
		return last
	}

	/// Finds the heading at or immediately before a UTF-16 source offset in an
	/// already parsed, source-ordered heading index. Raw editors use this after
	/// their cancellable index build completes so a deep scroll does not rescan
	/// the document prefix on the main actor.
	public static func heading(
		atCharacterOffset offset: Int,
		in headings: [MarkdownHeading]
	) -> MarkdownHeading? {
		var lowerBound = 0
		var upperBound = headings.count
		while lowerBound < upperBound {
			let middle = lowerBound + (upperBound - lowerBound) / 2
			if headings[middle].sourceRange.location <= offset {
				lowerBound = middle + 1
			} else {
				upperBound = middle
			}
		}
		guard lowerBound > 0 else { return nil }
		return headings[lowerBound - 1]
	}

	/// The source range of a heading ID by a single line scan; see
	/// `heading(atCharacterOffset:in:)` for when to prefer `parse`.
	public static func characterRange(for headingID: String, in text: String) -> NSRange? {
		var found: NSRange?
		scanHeadings(in: text) { heading in
			guard heading.id == headingID else { return true }
			found = heading.sourceRange
			return false
		}
		return found
	}

	/// Visits headings in order until `visit` returns false.
	private static func scanHeadings(in markdown: String, _ visit: (MarkdownHeading) -> Bool) {
		withoutActuallyEscaping(visit) { visit in
			scanHeadings(in: markdown, escaping: visit)
		}
	}

	private static func scanHeadings(in markdown: String, escaping visit: @escaping (MarkdownHeading) -> Bool) {
		var count = 0
		var fence: (character: Character, length: Int)?
		var inIndentedCode = false
		var previousLineBlank = true
		var previousLineListLike = false
		markdown.enumerateSubstrings(
			in: markdown.startIndex..<markdown.endIndex,
			options: [.byLines, .substringNotRequired]
		) { _, lineRange, _, stop in
			let line = markdown[lineRange]
			var indent = 0
			var content = line.startIndex
			while content < line.endIndex, line[content] == " " || line[content] == "\t" {
				indent += line[content] == "\t" ? 4 : 1
				content = line.index(after: content)
			}
			let trimmed = line[content...].trimmingCharacters(in: .whitespaces)
			let isBlank = trimmed.isEmpty
			defer {
				previousLineBlank = isBlank
				if !isBlank { previousLineListLike = indent >= 2 || isListItemLine(trimmed) }
			}
			// Fence lines may sit inside quotes; strip those markers only.
			var unquoted = Substring(trimmed)
			while unquoted.first == ">" { unquoted = unquoted.dropFirst().drop { $0 == " " } }
			if let open = fence {
				let run = unquoted.prefix { $0 == open.character }.count
				if run >= open.length, unquoted.dropFirst(run).allSatisfy({ $0 == " " || $0 == "\t" }) { fence = nil }
				return
			}
			if let character = unquoted.first, character == "`" || character == "~" {
				let run = unquoted.prefix { $0 == character }.count
				if run >= 3, character == "~" || !unquoted.dropFirst(run).contains("`") {
					fence = (character, run)
					inIndentedCode = false
					return
				}
			}
			if isBlank { return }
			if inIndentedCode {
				if indent >= 4 { return }
				inIndentedCode = false
			} else if indent >= 4, previousLineBlank, !previousLineListLike {
				inIndentedCode = true
				return
			}
			guard let (level, text) = parseHeadingLine(trimmed) else { return }
			let heading = MarkdownHeading(
				id: "\(count)-\(text)", level: level, text: text,
				sourceRange: NSRange(lineRange, in: markdown))
			count += 1
			if !visit(heading) { stop = true }
		}
	}

	private static func isListItemLine(_ trimmed: String) -> Bool {
		guard let first = trimmed.first else { return false }
		if first == "-" || first == "*" || first == "+" {
			let rest = trimmed.dropFirst()
			return rest.isEmpty || rest.first == " " || rest.first == "\t"
		}
		let digits = trimmed.prefix { $0.isNumber }
		guard !digits.isEmpty, digits.count <= 9 else { return false }
		let rest = trimmed.dropFirst(digits.count)
		guard let marker = rest.first, marker == "." || marker == ")" else { return false }
		let after = rest.dropFirst()
		return after.isEmpty || after.first == " " || after.first == "\t"
	}
}
