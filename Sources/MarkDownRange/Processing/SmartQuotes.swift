//
//  SmartQuotes.swift
//  MarkDownRange
//

import Foundation

/// Replaces straight ASCII quotes with curly typographic quotes, matching
/// markdown-it's `typographer + quotes` behaviour. Skips fenced code blocks
/// and inline code spans so source listings keep their ASCII quotes.
///
/// A `"` after whitespace or a sentence-opening boundary becomes `“`; the
/// closing partner becomes `”`. The same rule pairs `‘` / `’` for single
/// quotes, with a small concession for apostrophes inside words (`don't`,
/// `it's`) where the single quote sits between two letters.
public enum SmartQuotes {
	public static func process(_ text: String) -> String {
		guard text.contains("\"") || text.contains("'") else { return text }
		var output: [String] = []
		var inFence = false
		for line in text.components(separatedBy: "\n") {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
				inFence.toggle()
				output.append(line); continue
			}
			if inFence { output.append(line); continue }
			// Link reference definitions (`[label]: url "title"`) need the
			// title quotes to stay ASCII so the CommonMark parser still
			// recognises them; curling those mid-stream silently drops the
			// reference altogether.
			if isLinkReferenceDefinition(trimmed) { output.append(line); continue }
			output.append(processLine(line))
		}
		return output.joined(separator: "\n")
	}

	private static func isLinkReferenceDefinition(_ trimmed: String) -> Bool {
		guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { return false }
		let after = trimmed.index(after: close)
		return after < trimmed.endIndex && trimmed[after] == ":"
	}

	private static func processLine(_ line: String) -> String {
		var pieces: [String] = []
		var pending = ""
		var i = line.startIndex
		while i < line.endIndex {
			let ch = line[i]
			// Pass through inline code spans verbatim — `"foo"` shouldn't curl.
			if ch == "`" {
				if let close = line[line.index(after: i)...].firstIndex(of: "`") {
					if !pending.isEmpty { pieces.append(replacePlain(pending)); pending = "" }
					pieces.append(String(line[i...close]))
					i = line.index(after: close); continue
				}
			}
			// Pass through HTML tags verbatim — attribute values like
			// `title="..."` mustn't get curled into `title=“...”`, which would
			// break attribute parsing downstream.
			if ch == "<", let close = line[line.index(after: i)...].firstIndex(of: ">") {
				if !pending.isEmpty { pieces.append(replacePlain(pending)); pending = "" }
				pieces.append(String(line[i...close]))
				i = line.index(after: close); continue
			}
			pending.append(ch)
			i = line.index(after: i)
		}
		if !pending.isEmpty { pieces.append(replacePlain(pending)) }
		return pieces.joined()
	}

	private static func replacePlain(_ segment: String) -> String {
		var result = ""
		var i = segment.startIndex
		while i < segment.endIndex {
			let ch = segment[i]
			switch ch {
			case "\"":
				result.append(opensQuote(at: i, in: segment) ? "“" : "”")
			case "'":
				// Apostrophe inside a word (`don't`, `it's`) keeps its
				// closing form so abbreviations and contractions look right.
				if i > segment.startIndex,
				   i < segment.index(before: segment.endIndex),
				   segment[segment.index(before: i)].isLetter,
				   segment[segment.index(after: i)].isLetter {
					result.append("’")
				} else {
					result.append(opensQuote(at: i, in: segment) ? "‘" : "’")
				}
			default:
				result.append(ch)
			}
			i = segment.index(after: i)
		}
		return result
	}

	private static func opensQuote(at i: String.Index, in segment: String) -> Bool {
		guard i > segment.startIndex else { return true }
		let prev = segment[segment.index(before: i)]
		return prev.isWhitespace || prev == "(" || prev == "[" || prev == "{" || prev == "—" || prev == "–"
	}
}
