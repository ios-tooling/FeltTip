//
//  MarkdownFootnote.swift
//  MarkdownRendering
//

import Foundation

public struct MarkdownFootnote: Identifiable, Equatable, Sendable {
	public let id: String          // label for named footnotes, "inline-N" for inline
	public let content: String
	public let displayIndex: Int   // 1-based, order of first appearance in document

	/// Parses all footnotes — named references ([^label]) and inline (^[content]) —
	/// ordered by first occurrence in the document.
	public static func parse(from text: String) -> [MarkdownFootnote] {
		// First pass: collect named definitions
		var definitions: [String: String] = [:]
		var inCodeBlock = false
		for line in text.components(separatedBy: .newlines) {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("```") { inCodeBlock.toggle(); continue }
			if inCodeBlock { continue }
			if let m = trimmed.firstMatch(of: /^\[\^([^\]]+)\]:\s+(.+)/) {
				definitions[String(m.1)] = String(m.2)
			}
		}

		// Second pass: scan body text for references and inline footnotes in order
		var footnotes: [MarkdownFootnote] = []
		var seenLabels = Set<String>()
		inCodeBlock = false
		var counter = 0

		for line in text.components(separatedBy: .newlines) {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("```") { inCodeBlock.toggle(); continue }
			if inCodeBlock { continue }
			if trimmed.firstMatch(of: /^\[\^[^\]]+\]:\s+/) != nil { continue }

			for match in trimmed.matches(of: /\[\^([^\]]+)\]|\^\[([^\]]+)\]/) {
				if let label = match.output.1.map(String.init) {
					guard !seenLabels.contains(label), let content = definitions[label] else { continue }
					seenLabels.insert(label)
					counter += 1
					footnotes.append(MarkdownFootnote(id: label, content: content, displayIndex: counter))
				} else if let content = match.output.2.map(String.init) {
					counter += 1
					footnotes.append(MarkdownFootnote(id: "inline-\(counter)", content: content, displayIndex: counter))
				}
			}
		}

		return footnotes
	}

	/// Returns text with footnote syntax removed for clean rendering.
	public static func cleanedForRendering(from text: String) -> String {
		var inCodeBlock = false
		var lines: [String] = []
		for line in text.components(separatedBy: .newlines) {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("```") { inCodeBlock.toggle() }
			if inCodeBlock { lines.append(line); continue }
			if trimmed.firstMatch(of: /^\[\^[^\]]+\]:\s+/) != nil { continue }
			let processed = line
				.replacing(/\[\^[^\]]+\]/, with: "")
				.replacing(/\^\[[^\]]+\]/, with: "")
			lines.append(processed)
		}
		return lines.joined(separator: "\n")
	}
}
