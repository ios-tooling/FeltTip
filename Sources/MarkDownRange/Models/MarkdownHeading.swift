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

			if let match = trimmed.firstMatch(of: /^(#{1,6})\s+(.+)/) {
				let level = match.1.count
				let text = String(match.2)
				let id = "\(headings.count)-\(text)"
				headings.append(MarkdownHeading(id: id, level: level, text: text))
			}
		}
		return headings
	}

	public static func heading(atCharacterOffset offset: Int, in text: String) -> MarkdownHeading? {
		var inCodeBlock = false
		var headingIndex = 0
		var charOffset = 0
		var lastHeading: MarkdownHeading?

		for line in text.components(separatedBy: .newlines) {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("```") { inCodeBlock.toggle() }

			if !inCodeBlock, let match = trimmed.firstMatch(of: /^(#{1,6})\s+(.+)/) {
				let heading = MarkdownHeading(id: "\(headingIndex)-\(match.2)", level: match.1.count, text: String(match.2))
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

			if !inCodeBlock, let match = trimmed.firstMatch(of: /^(#{1,6})\s+(.+)/) {
				let id = "\(headingIndex)-\(match.2)"
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
