//
//  HighlightSyntax.swift
//  MarkDownRange
//

import Foundation

public enum HighlightSyntax {
	public static func process(_ text: String) -> String {
		guard text.contains("==") else { return text }
		var output: [String] = []
		var inFence = false
		for line in text.components(separatedBy: "\n") {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
				inFence.toggle()
				output.append(line); continue
			}
			if inFence { output.append(line); continue }
			// Setext H1 underlines are runs of `=` characters; the highlight
			// regex would eat them as overlapping `==…==` spans and turn each
			// pair into a `<mark>` block, breaking the heading.
			if !trimmed.isEmpty, trimmed.allSatisfy({ $0 == "=" || $0.isWhitespace }) {
				output.append(line); continue
			}
			output.append(String(line.replacing(/==([^=].*?)==/) { "<mark>\($0.1)</mark>" }))
		}
		return output.joined(separator: "\n")
	}
}
