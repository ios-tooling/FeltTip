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

	public static func heading(atCharacterOffset offset: Int, in text: String) -> MarkdownHeading? {
		heading(atCharacterOffset: offset, in: parse(from: text))
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

	public static func characterRange(for headingID: String, in text: String) -> NSRange? {
		parse(from: text).first { $0.id == headingID }?.sourceRange
	}
}
