//
//  AbbreviationProcessor.swift
//  FeltTip
//

import Foundation

/// Pandoc / markdown-it style abbreviations:
///
///     *[HTML]: HyperText Markup Language
///     *[CSS]:  Cascading Style Sheets
///
///     HTML and CSS are great.
///
/// Definitions are stripped from the body; subsequent whole-word occurrences
/// of each abbreviation key are wrapped in `<abbr title="...">…</abbr>` so the
/// inline builder can pick them up via its existing HTML handling. Skips
/// fenced code blocks and inline code spans so source listings aren't
/// rewritten.
public enum AbbreviationProcessor {
	public static func process(_ text: String) -> String {
		MarkdownCodeProtection.transform(text) { processUnprotected($0) } ?? text
	}

	private static func processUnprotected(_ text: String) -> String {
		// `**[link](url)**` appears in nearly every README; only a `*[KEY]: value`
		// line at the start of a line defines anything.
		guard DocumentScan.hasBracketColonDefinitionLine(
			startingWith: "*[", minimumLabel: 0, in: text) else { return text }
		let (definitions, withoutDefs) = extractDefinitions(text)
		guard !definitions.isEmpty else { return text }
		return rewriteOccurrences(in: withoutDefs, definitions: definitions)
	}

	private static func extractDefinitions(_ text: String) -> (definitions: [String: String], stripped: String) {
		var definitions: [String: String] = [:]
		var kept: [String] = []
		var inFence = false
		for line in text.components(separatedBy: "\n") {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
				inFence.toggle()
				kept.append(line); continue
			}
			if !inFence, let definition = parseDefinition(trimmed) {
				definitions[definition.key] = definition.value
				continue
			}
			kept.append(line)
		}
		return (definitions, kept.joined(separator: "\n"))
	}

	private static func parseDefinition(_ line: String) -> (key: String, value: String)? {
		guard line.hasPrefix("*["),
			  let closeBracket = line.firstIndex(of: "]"),
			  line.index(after: closeBracket) < line.endIndex,
			  line[line.index(after: closeBracket)] == ":" else { return nil }
		let keyStart = line.index(line.startIndex, offsetBy: 2)
		guard keyStart < closeBracket else { return nil }
		let key = String(line[keyStart..<closeBracket]).trimmingCharacters(in: .whitespaces)
		let valueStart = line.index(after: line.index(after: closeBracket))
		guard valueStart <= line.endIndex else { return nil }
		let value = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
		guard !key.isEmpty, !value.isEmpty else { return nil }
		return (key, value)
	}

	private static func rewriteOccurrences(in text: String, definitions: [String: String]) -> String {
		// Longest keys first so `HTML5` wins over `HTML` when both are defined.
		let sortedKeys = definitions.keys.sorted { $0.count > $1.count }
		var output: [String] = []
		var inFence = false
		for line in text.components(separatedBy: "\n") {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
				inFence.toggle()
				output.append(line); continue
			}
			if inFence { output.append(line); continue }
			output.append(rewriteLine(line, keys: sortedKeys, definitions: definitions))
		}
		return output.joined(separator: "\n")
	}

	private static func rewriteLine(_ line: String, keys: [String], definitions: [String: String]) -> String {
		var pieces: [String] = []
		var pending = ""
		var i = line.startIndex
		while i < line.endIndex {
			let ch = line[i]
			if ch == "`" {
				if let close = line[line.index(after: i)...].firstIndex(of: "`") {
					if !pending.isEmpty { pieces.append(rewritePlain(pending, keys: keys, definitions: definitions)); pending = "" }
					pieces.append(String(line[i...close]))
					i = line.index(after: close); continue
				}
			}
			pending.append(ch)
			i = line.index(after: i)
		}
		if !pending.isEmpty { pieces.append(rewritePlain(pending, keys: keys, definitions: definitions)) }
		return pieces.joined()
	}

	private static func rewritePlain(_ segment: String, keys: [String], definitions: [String: String]) -> String {
		var result = segment
		for key in keys {
			guard let title = definitions[key] else { continue }
			let escaped = title.replacingOccurrences(of: "\"", with: "&quot;")
			result = replaceWholeWord(of: key, in: result, with: "<abbr title=\"\(escaped)\">\(key)</abbr>")
		}
		return result
	}

	private static func replaceWholeWord(of key: String, in text: String, with replacement: String) -> String {
		guard !key.isEmpty else { return text }
		var output = ""
		var i = text.startIndex
		while i < text.endIndex {
			if text[i...].hasPrefix(key),
			   isWordBoundary(before: i, in: text),
			   isWordBoundary(after: text.index(i, offsetBy: key.count, limitedBy: text.endIndex) ?? text.endIndex, in: text) {
				output.append(replacement)
				i = text.index(i, offsetBy: key.count)
				continue
			}
			output.append(text[i])
			i = text.index(after: i)
		}
		return output
	}

	private static func isWordBoundary(before i: String.Index, in text: String) -> Bool {
		guard i > text.startIndex else { return true }
		let prev = text[text.index(before: i)]
		return !(prev.isLetter || prev.isNumber || prev == "_")
	}

	private static func isWordBoundary(after i: String.Index, in text: String) -> Bool {
		guard i < text.endIndex else { return true }
		let ch = text[i]
		return !(ch.isLetter || ch.isNumber || ch == "_")
	}
}
