//
//  Citation.swift
//  MarkDownRange
//

import Foundation

public struct Citation: Identifiable, Equatable, Sendable {
	public let id: String
	public let content: String
	public let displayIndex: Int

	/// Parses citations from markdown text.
	/// Definitions: `[@key]: Author. Title. Year.`
	/// References: `[@key]` in body text.
	public static func parse(from text: String) -> [Citation] {
		var definitions: [String: String] = [:]
		var inCodeBlock = false

		// First pass: collect definitions
		for line in text.components(separatedBy: .newlines) {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("```") { inCodeBlock.toggle(); continue }
			if inCodeBlock { continue }
			if let (key, content) = parseDefinition(trimmed) {
				definitions[key] = content
			}
		}

		// Second pass: collect references in order
		var citations: [Citation] = []
		var seenKeys = Set<String>()
		inCodeBlock = false
		var counter = 0

		for line in text.components(separatedBy: .newlines) {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("```") { inCodeBlock.toggle(); continue }
			if inCodeBlock { continue }
			if parseDefinition(trimmed) != nil { continue }

			scanReferences(in: trimmed) { key in
				guard !seenKeys.contains(key), let content = definitions[key] else { return }
				seenKeys.insert(key)
				counter += 1
				citations.append(Citation(id: key, content: content, displayIndex: counter))
			}
		}

		return citations
	}

	/// Returns text with citation markers replaced by numbered superscript links.
	public static func renderableContent(from text: String, citations: [Citation]) -> String {
		guard !citations.isEmpty else { return text }

		let indexByID = Dictionary(uniqueKeysWithValues: citations.map { ($0.id, $0.displayIndex) })
		var inCodeBlock = false
		var lines: [String] = []

		for line in text.components(separatedBy: .newlines) {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("```") { inCodeBlock.toggle() }
			if inCodeBlock { lines.append(line); continue }
			if parseDefinition(trimmed) != nil { continue }

			guard line.contains("[@") else { lines.append(line); continue }

			var result = ""
			var i = line.startIndex
			while i < line.endIndex {
				if line[i] == "[", line.index(after: i) < line.endIndex, line[line.index(after: i)] == "@" {
					let keyStart = line.index(i, offsetBy: 2)
					if let closeIdx = line[keyStart...].firstIndex(of: "]") {
						let key = String(line[keyStart..<closeIdx])
						if let n = indexByID[key] {
							let sup = MarkdownFootnote.superscript(for: n)
							result += "[\(sup)](citation://\(key))"
						}
						i = line.index(after: closeIdx)
						continue
					}
				}
				result.append(line[i])
				i = line.index(after: i)
			}
			lines.append(result)
		}
		return lines.joined(separator: "\n")
	}

	/// Parse `[@key]: content` definition line.
	public static func parseDefinition(_ line: String) -> (key: String, content: String)? {
		guard line.hasPrefix("[@") else { return nil }
		guard let closeIdx = line.firstIndex(of: "]") else { return nil }
		let keyStart = line.index(line.startIndex, offsetBy: 2)
		guard closeIdx > keyStart else { return nil }
		let afterClose = line.index(after: closeIdx)
		guard afterClose < line.endIndex, line[afterClose] == ":" else { return nil }
		let key = String(line[keyStart..<closeIdx])
		let contentStart = line.index(after: afterClose)
		let content = String(line[contentStart...]).trimmingCharacters(in: .whitespaces)
		guard !content.isEmpty else { return nil }
		return (key, content)
	}

	/// Scan a line for `[@key]` references.
	private static func scanReferences(in line: String, handler: (String) -> Void) {
		guard line.contains("[@") else { return }
		var i = line.startIndex
		while i < line.endIndex {
			if line[i] == "[", line.index(after: i) < line.endIndex, line[line.index(after: i)] == "@" {
				let keyStart = line.index(i, offsetBy: 2)
				if let closeIdx = line[keyStart...].firstIndex(of: "]") {
					let afterClose = line.index(after: closeIdx)
					// Not a definition (no : after ])
					if afterClose >= line.endIndex || line[afterClose] != ":" {
						let key = String(line[keyStart..<closeIdx])
						if !key.isEmpty { handler(key) }
					}
					i = afterClose
					continue
				}
			}
			i = line.index(after: i)
		}
	}
}
