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
		// Normal documents should not pay for two arrays of every source line.
		// A cheap syntax check also keeps absent-feature preprocessing
		// responsive for very large files.
		// Named references need a `[^label]:` definition line to produce
		// anything; inline `^[…]` footnotes need nothing else.
		guard DocumentScan.hasBracketColonDefinitionLine(startingWith: "[^", minimumLabel: 1, in: text)
			|| (text as NSString).range(of: "^[").location != NSNotFound else { return [] }
		// First pass: collect named definitions
		var definitions: [String: String] = [:]
		var inCodeBlock = false
		for line in text.components(separatedBy: .newlines) {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("```") { inCodeBlock.toggle(); continue }
			if inCodeBlock { continue }
			if let (label, content) = parseDefinition(trimmed) {
				definitions[label] = content
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
			if parseDefinition(trimmed) != nil { continue }

			scanReferences(in: trimmed) { ref in
				switch ref {
				case .named(let label):
					guard !seenLabels.contains(label), let content = definitions[label] else { return }
					seenLabels.insert(label)
					counter += 1
					footnotes.append(MarkdownFootnote(id: label, content: content, displayIndex: counter))
				case .inline(let content):
					counter += 1
					footnotes.append(MarkdownFootnote(id: "inline-\(counter)", content: content, displayIndex: counter))
				}
			}
		}

		return footnotes
	}

	/// Parse a `[^label]: content` definition line. Returns nil for non-definition lines.
	static func parseDefinition(_ line: String) -> (label: String, content: String)? {
		guard line.hasPrefix("[^") else { return nil }
		guard let closeIdx = line.firstIndex(of: "]") else { return nil }
		let labelStart = line.index(line.startIndex, offsetBy: 2)
		guard closeIdx > labelStart else { return nil }
		let afterClose = line.index(after: closeIdx)
		guard afterClose < line.endIndex, line[afterClose] == ":" else { return nil }
		let label = String(line[labelStart..<closeIdx])
		let contentStart = line.index(after: afterClose)
		let content = String(line[contentStart...]).trimmingCharacters(in: .whitespaces)
		guard !content.isEmpty else { return nil }
		return (label, content)
	}

	private enum FootnoteRef {
		case named(String)
		case inline(String)
	}

	/// Scan a line for `[^label]` references and `^[content]` inline footnotes.
	private static func scanReferences(in line: String, handler: (FootnoteRef) -> Void) {
		guard line.contains("[") else { return }
		var i = line.startIndex
		while i < line.endIndex {
			let ch = line[i]
			if ch == "[", line.index(after: i) < line.endIndex, line[line.index(after: i)] == "^" {
				// Named reference: [^label]
				let labelStart = line.index(i, offsetBy: 2)
				if let closeIdx = line[labelStart...].firstIndex(of: "]") {
					// Make sure this isn't a definition (no : after ])
					let afterClose = line.index(after: closeIdx)
					if afterClose >= line.endIndex || line[afterClose] != ":" {
						let label = String(line[labelStart..<closeIdx])
						if !label.isEmpty { handler(.named(label)) }
					}
					i = afterClose
					continue
				}
			} else if ch == "^", line.index(after: i) < line.endIndex, line[line.index(after: i)] == "[" {
				// Inline footnote: ^[content]
				let contentStart = line.index(i, offsetBy: 2)
				if let closeIdx = line[contentStart...].firstIndex(of: "]") {
					let content = String(line[contentStart..<closeIdx])
					if !content.isEmpty { handler(.inline(content)) }
					i = line.index(after: closeIdx)
					continue
				}
			}
			i = line.index(after: i)
		}
	}

	/// Returns text with footnote syntax removed for clean rendering.
	public static func cleanedForRendering(from text: String) -> String {
		var inCodeBlock = false
		var lines: [String] = []
		for line in text.components(separatedBy: "\n") {
			let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
			if trimmed.hasPrefix("```") { inCodeBlock.toggle() }
			if inCodeBlock { lines.append(line); continue }
			if parseDefinition(trimmed) != nil { continue }
			lines.append(stripFootnoteMarkers(from: line))
		}
		return lines.joined(separator: "\n")
	}

	/// Strip `[^label]` and `^[content]` markers from a line without regex.
	private static func stripFootnoteMarkers(from line: String) -> String {
		guard line.contains("[") else { return line }
		var result = ""
		var i = line.startIndex
		while i < line.endIndex {
			let ch = line[i]
			if ch == "[", line.index(after: i) < line.endIndex, line[line.index(after: i)] == "^" {
				let labelStart = line.index(i, offsetBy: 2)
				if let closeIdx = line[labelStart...].firstIndex(of: "]") {
					let afterClose = line.index(after: closeIdx)
					if afterClose >= line.endIndex || line[afterClose] != ":" {
						i = afterClose; continue // skip [^label]
					}
				}
			} else if ch == "^", line.index(after: i) < line.endIndex, line[line.index(after: i)] == "[" {
				let contentStart = line.index(i, offsetBy: 2)
				if let closeIdx = line[contentStart...].firstIndex(of: "]") {
					i = line.index(after: closeIdx); continue // skip ^[content]
				}
			}
			result.append(ch)
			i = line.index(after: i)
		}
		return result
	}
}
