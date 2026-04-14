//
//  MarkdownSection.swift
//  MarkdownRendering
//

import Foundation

public struct MarkdownSection: Identifiable, Sendable {
	public let id: String
	public let content: String

	public static func parse(from markdown: String) -> [MarkdownSection] {
		var sections: [MarkdownSection] = []
		var currentLines: [String] = []
		var currentID = "preamble"
		var headingIndex = 0
		var inCodeBlock = false

		for line in markdown.components(separatedBy: .newlines) {
			let trimmed = line.trimmingCharacters(in: .whitespaces)

			if trimmed.hasPrefix("```") { inCodeBlock.toggle() }

			if !inCodeBlock, let match = trimmed.firstMatch(of: /^#{1,6}\s+(.+)/) {
				if !currentLines.isEmpty {
					sections.append(MarkdownSection(id: currentID, content: currentLines.joined(separator: "\n")))
				}
				currentID = "\(headingIndex)-\(match.1)"
				headingIndex += 1
				currentLines = [line]
			} else {
				currentLines.append(line)
			}
		}

		if !currentLines.isEmpty {
			sections.append(MarkdownSection(id: currentID, content: currentLines.joined(separator: "\n")))
		}
		return sections
	}
}
