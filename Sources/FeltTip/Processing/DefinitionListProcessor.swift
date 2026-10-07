//
//  DefinitionListProcessor.swift
//  FeltTip
//

import Foundation

public enum DefinitionListProcessor {
	struct SourceItem {
		let term: String
		let definitions: [String]
		let termStart: Int
		let definitionStarts: [Int]
	}

	/// Converts definition list syntax (`term\n: definition`) into `<dl>` HTML
	/// blocks that survive CommonMark parsing as HTML blocks.
	public static func process(_ text: String) -> String {
		// A list needs a `: definition` line; a leading colon alone (emoji
		// shortcodes at the start of a line, say) is not one.
		guard DocumentScan.hasDefinitionListLine(in: text) else { return text }

		var result: [String] = []
		let lines = text.components(separatedBy: .newlines)
		var i = 0
		var inCodeBlock = false
		var generatedListIndex = 0

		while i < lines.count {
			let line = lines[i]
			let trimmed = line.trimmingCharacters(in: .whitespaces)

			if trimmed.hasPrefix("```") { inCodeBlock.toggle() }
			if inCodeBlock { result.append(line); i += 1; continue }

			// Look for: non-empty term line followed by one or more `: definition` lines
			if !trimmed.isEmpty,
			   !trimmed.hasPrefix(":"),
			   !trimmed.hasPrefix("#"),
			   !trimmed.hasPrefix(">"),
			   !trimmed.hasPrefix("-"),
			   !trimmed.hasPrefix("*"),
			   !trimmed.hasPrefix("<"),
			   i + 1 < lines.count,
			   isDefinitionLine(lines[i + 1]) {

				var html = "<dl data-feltip-definition-list=\"\(generatedListIndex)\">\n<dt>\(trimmed)</dt>"
				generatedListIndex += 1
				i += 1

				// Collect consecutive definition lines
				while i < lines.count, isDefinitionLine(lines[i]) {
					let def = extractDefinition(lines[i])
					html += "\n<dd>\(def)</dd>"
					i += 1
				}

				// Check for more term+definition groups (separated by blank line)
				while i < lines.count {
					// Skip blank lines between items
					if lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
						let next = i + 1
						if next < lines.count,
						   !lines[next].trimmingCharacters(in: .whitespaces).isEmpty,
						   !isDefinitionLine(lines[next]),
						   next + 1 < lines.count,
						   isDefinitionLine(lines[next + 1]) {
							i = next
							let term = lines[i].trimmingCharacters(in: .whitespaces)
							html += "\n<dt>\(term)</dt>"
							i += 1
							while i < lines.count, isDefinitionLine(lines[i]) {
								html += "\n<dd>\(extractDefinition(lines[i]))</dd>"
								i += 1
							}
							continue
						}
					}
					break
				}

				html += "\n</dl>"
				result.append(html)
			} else {
				result.append(line)
				i += 1
			}
		}

		return result.joined(separator: "\n")
	}

	/// Finds the original inline strings and UTF-16 starts for each generated
	/// list. The generated HTML carries the matching group index so authored
	/// raw-HTML `<dl>` blocks are never assigned Markdown source offsets.
	static func sourceGroups(in text: String, baseOffset: Int) -> [[SourceItem]] {
		guard DocumentScan.hasDefinitionListLine(in: text) else { return [] }
		let lines = text.components(separatedBy: .newlines)
		var starts: [Int] = []
		var cursor = 0
		for line in lines {
			starts.append(cursor)
			cursor += (line as NSString).length + 1
		}

		func sourceStart(line: String, trimmed: String, lineStart: Int, dropping: Int) -> Int {
			let leading = (line as NSString).range(of: trimmed).location
			return baseOffset + lineStart + max(0, leading) + dropping
		}

		var groups: [[SourceItem]] = []
		var i = 0
		var inCodeBlock = false
		while i < lines.count {
			let line = lines[i]
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("```") { inCodeBlock.toggle() }
			if inCodeBlock { i += 1; continue }
			guard !trimmed.isEmpty,
				  !trimmed.hasPrefix(":"), !trimmed.hasPrefix("#"),
				  !trimmed.hasPrefix(">"), !trimmed.hasPrefix("-"),
				  !trimmed.hasPrefix("*"), !trimmed.hasPrefix("<"),
				  i + 1 < lines.count, isDefinitionLine(lines[i + 1]) else {
				i += 1
				continue
			}

			var items: [SourceItem] = []
			while true {
				let term = lines[i].trimmingCharacters(in: .whitespaces)
				let termStart = sourceStart(
					line: lines[i], trimmed: term, lineStart: starts[i], dropping: 0)
				i += 1
				var definitions: [String] = []
				var definitionStarts: [Int] = []
				while i < lines.count, isDefinitionLine(lines[i]) {
					let definitionLine = lines[i]
					let definitionTrimmed = definitionLine.trimmingCharacters(in: .whitespaces)
					definitions.append(extractDefinition(definitionLine))
					definitionStarts.append(sourceStart(
						line: definitionLine, trimmed: definitionTrimmed,
						lineStart: starts[i], dropping: definitionTrimmed.hasPrefix(": ") ? 2 : 1))
					i += 1
				}
				items.append(SourceItem(
					term: term, definitions: definitions, termStart: termStart,
					definitionStarts: definitionStarts))

				guard i < lines.count,
					  lines[i].trimmingCharacters(in: .whitespaces).isEmpty else { break }
				let next = i + 1
				guard next < lines.count,
					  !lines[next].trimmingCharacters(in: .whitespaces).isEmpty,
					  !isDefinitionLine(lines[next]), next + 1 < lines.count,
					  isDefinitionLine(lines[next + 1]) else { break }
				i = next
			}
			groups.append(items)
		}
		return groups
	}

	private static func isDefinitionLine(_ line: String) -> Bool {
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		return trimmed.hasPrefix(": ") || trimmed == ":"
	}

	private static func extractDefinition(_ line: String) -> String {
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		guard trimmed.hasPrefix(": ") else { return trimmed }
		return String(trimmed.dropFirst(2))
	}
}
