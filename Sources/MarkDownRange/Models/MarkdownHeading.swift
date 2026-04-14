//
//  MarkdownHeading.swift
//  MarkdownRendering
//

import Foundation

public struct MarkdownHeading: Identifiable, Equatable, Sendable {
	public let id: String
	public let level: Int
	public let text: String

	public static func parse(from markdown: String) -> [MarkdownHeading] {
		var headings: [MarkdownHeading] = []
		var inCodeBlock = false

		for line in markdown.components(separatedBy: .newlines) {
			let trimmed = line.trimmingCharacters(in: .whitespaces)

			if trimmed.hasPrefix("```") {
				inCodeBlock.toggle()
				continue
			}
			if inCodeBlock { continue }

			if let (level, text) = parseHeadingLine(trimmed) {
				let id = "\(headings.count)-\(text)"
				headings.append(MarkdownHeading(id: id, level: level, text: text))
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
		var inCodeBlock = false
		var headingIndex = 0
		var charOffset = 0
		var lastHeading: MarkdownHeading?

		for line in text.components(separatedBy: .newlines) {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("```") { inCodeBlock.toggle() }

			if !inCodeBlock, let (level, headingText) = parseHeadingLine(trimmed) {
				let heading = MarkdownHeading(id: "\(headingIndex)-\(headingText)", level: level, text: headingText)
				if charOffset > offset { return lastHeading }
				lastHeading = heading
				headingIndex += 1
			}
			charOffset += line.count + 1
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
					return NSRange(location: charOffset, length: line.count)
				}
				headingIndex += 1
			}
			charOffset += line.count + 1
		}
		return nil
	}
}
