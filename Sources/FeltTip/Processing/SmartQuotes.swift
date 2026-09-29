//
//  SmartQuotes.swift
//  FeltTip
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
		var referenceContinuationLines = 0
		for line in text.components(separatedBy: "\n") {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
				inFence.toggle()
				referenceContinuationLines = 0
				output.append(line); continue
			}
			if inFence { output.append(line); continue }
			// Link reference definitions (`[label]: url "title"`) need the
			// title quotes to stay ASCII so the CommonMark parser still
			// recognises them; curling those mid-stream silently drops the
			// reference altogether.
			var preservesReferenceSyntax = false
			if referenceContinuationLines > 0,
			   !trimmed.isEmpty,
			   (line.first == " " || line.first == "\t") {
				preservesReferenceSyntax = true
				referenceContinuationLines -= 1
			} else if !trimmed.isEmpty {
				referenceContinuationLines = 0
			}
			if let continuationLimit = referenceDefinitionContinuationLimit(trimmed) {
				preservesReferenceSyntax = true
				referenceContinuationLines = continuationLimit
			}
			if preservesReferenceSyntax { output.append(line); continue }
			output.append(processLine(line))
		}
		return output.joined(separator: "\n")
	}

	static func isLinkReferenceDefinition(_ trimmed: String) -> Bool {
		guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { return false }
		let after = trimmed.index(after: close)
		return after < trimmed.endIndex && trimmed[after] == ":"
	}

	/// Number of indented destination/title lines that may follow a reference
	/// definition opener. Those lines must retain straight quote delimiters so
	/// CommonMark can recognize an optional title.
	static func referenceDefinitionContinuationLimit(_ trimmed: String) -> Int? {
		guard isLinkReferenceDefinition(trimmed), let close = trimmed.firstIndex(of: "]") else {
			return nil
		}
		let colon = trimmed.index(after: close)
		let remainder = trimmed[trimmed.index(after: colon)...]
			.trimmingCharacters(in: .whitespaces)
		return remainder.isEmpty ? 2 : 1
	}

	/// Per-line variant used by `MarkdownPreprocessor.mergedLinePass`.
	static func applyLine(_ line: String) -> String {
		if !line.contains("\"") && !line.contains("'") { return line }
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		// Link reference definitions need their title quotes left as ASCII
		// or the CommonMark parser stops recognising them.
		if isLinkReferenceDefinition(trimmed) { return line }
		return processLine(line)
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
			// Pass through markdown link / image destinations verbatim. The
			// title delimiter in `[txt](url "caption")` and `![alt](url "cap")`
			// must stay ASCII so CommonMark recognises the title; curling it
			// silently drops the title (and on images, kills the entire image
			// parse, leaving authors with literal text in the output).
			if ch == "(", isLinkOrImageDestinationOpener(at: i, in: line),
			   let close = matchingCloseParen(after: i, in: line) {
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

	/// True if the `(` at `i` follows the `]` of a markdown link or image
	/// label, i.e. the next character after `](`. The check is intentionally
	/// loose — false positives just leak a `(...)` region through the
	/// passthrough path without curling its contents, which is the safe
	/// failure mode for content that contains quoted text.
	private static func isLinkOrImageDestinationOpener(at i: String.Index, in line: String) -> Bool {
		guard i > line.startIndex else { return false }
		return line[line.index(before: i)] == "]"
	}

	/// Returns the index of the `)` that closes the `(` at `start`, honoring
	/// nested parens. Returns `nil` if the line has no matching close paren.
	private static func matchingCloseParen(after start: String.Index, in line: String) -> String.Index? {
		var depth = 1
		var j = line.index(after: start)
		while j < line.endIndex {
			let c = line[j]
			if c == "(" { depth += 1 }
			else if c == ")" {
				depth -= 1
				if depth == 0 { return j }
			}
			j = line.index(after: j)
		}
		return nil
	}

	private static func opensQuote(at i: String.Index, in segment: String) -> Bool {
		guard i > segment.startIndex else { return true }
		let prev = segment[segment.index(before: i)]
		return prev.isWhitespace || prev == "(" || prev == "[" || prev == "{" || prev == "—" || prev == "–"
	}
}
