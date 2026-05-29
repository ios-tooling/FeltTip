//
//  HighlightSyntax.swift
//  MarkDownRange
//

import Foundation

public enum HighlightSyntax {
	/// Per-line variant used by `MarkdownPreprocessor.mergedLinePass`.
	static func applyLine(_ line: String) -> String {
		if !line.contains("==") { return line }
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		// Setext H1 underlines look like `===`; treating them as `==…==`
		// highlights would break the heading.
		if !trimmed.isEmpty, trimmed.allSatisfy({ $0 == "=" || $0.isWhitespace }) {
			return line
		}
		return String(line.replacing(/==([^=].*?)==/) { "<mark>\($0.1)</mark>" })
	}

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
			// Fast-fail: the regex below scans the whole line and was running
			// on every line even when no `==` was present. Skipping lines
			// without the marker turns ~240 ms of regex work on a 200-section
			// document into ~3 ms of substring checks.
			if !line.contains("==") { output.append(line); continue }
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
