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
		var inCodeBlock = false
		var sourceOffset = 0

		for line in markdown.components(separatedBy: .newlines) {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			let lineLength = line.utf16.count

			if trimmed.hasPrefix("```") {
				inCodeBlock.toggle()
				sourceOffset += lineLength + 1
				continue
			}
			if inCodeBlock {
				sourceOffset += lineLength + 1
				continue
			}

			if let (level, text) = parseHeadingLine(trimmed) {
				let id = "\(headings.count)-\(text)"
				headings.append(MarkdownHeading(
					id: id, level: level, text: text,
					sourceRange: NSRange(location: sourceOffset, length: lineLength)))
			}
			sourceOffset += lineLength + 1
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
		var inCodeBlock = false
		var headingIndex = 0
		var charOffset = 0
		var lastHeading: MarkdownHeading?

		// Walk the string manually instead of allocating a substring per line
		// via components(separatedBy:). This runs on every scroll tick the
		// document's visible heading changes, so the allocation pressure adds
		// up.
		var lineStart = text.startIndex
		let end = text.endIndex
		while lineStart <= end {
			let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? end
			let line = text[lineStart..<lineEnd]
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("```") { inCodeBlock.toggle() }
			if !inCodeBlock, let (level, headingText) = parseHeadingLine(trimmed) {
				let heading = MarkdownHeading(
					id: "\(headingIndex)-\(headingText)", level: level, text: headingText,
					sourceRange: NSRange(location: charOffset, length: line.utf16.count))
				if charOffset > offset { return lastHeading }
				lastHeading = heading
				headingIndex += 1
			}
			// Every caller supplies NSTextView / JavaScript source offsets,
			// which are UTF-16. Swift `Character` counts drift as soon as a
			// preceding line contains emoji or a composed character.
			charOffset += line.utf16.count + 1
			if lineEnd == end { break }
			lineStart = text.index(after: lineEnd)
		}
		return lastHeading
	}

	public static func characterRange(for headingID: String, in text: String) -> NSRange? {
		var inCodeBlock = false
		var headingIndex = 0
		var charOffset = 0

		for line in text.components(separatedBy: .newlines) {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("```") { inCodeBlock.toggle() }

			if !inCodeBlock, let (_, headingText) = parseHeadingLine(trimmed) {
				let id = "\(headingIndex)-\(headingText)"
				if id == headingID {
					return NSRange(location: charOffset, length: line.utf16.count)
				}
				headingIndex += 1
			}
			charOffset += line.utf16.count + 1
		}
		return nil
	}
}
