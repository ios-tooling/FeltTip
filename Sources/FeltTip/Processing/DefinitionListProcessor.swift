//
//  DefinitionListProcessor.swift
//  FeltTip
//

import Foundation

public enum DefinitionListProcessor {
	/// Converts definition list syntax (`term\n: definition`) into `<dl>` HTML
	/// blocks that survive CommonMark parsing as HTML blocks.
	public static func process(_ text: String) -> String {
		guard text.hasPrefix(":")
			|| (text as NSString).range(of: "\n:").location != NSNotFound else { return text }

		var result: [String] = []
		let lines = text.components(separatedBy: .newlines)
		var i = 0
		var inCodeBlock = false

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

				var html = "<dl>\n<dt>\(trimmed)</dt>"
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
