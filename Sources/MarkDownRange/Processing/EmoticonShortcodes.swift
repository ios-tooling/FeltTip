//
//  EmoticonShortcodes.swift
//  MarkDownRange
//

import Foundation

/// Converts plain-text emoticons like `:-)` and `;)` into their emoji equivalents.
/// Skips fenced code blocks and inline code spans, and only matches emoticons
/// surrounded by whitespace (or at line boundaries) so we don't rewrite tokens
/// in URLs or identifiers.
public enum EmoticonShortcodes {
	public static func process(_ text: String) -> String {
		guard text.contains(":") || text.contains(";") || text.contains("8") || text.contains("=") else { return text }
		var output: [String] = []
		var inFence = false
		for line in text.components(separatedBy: "\n") {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
				inFence.toggle()
				output.append(line); continue
			}
			if inFence { output.append(line); continue }
			// Per-line fast-fail: the char-by-char scan in `processLine` is
			// the expensive part. Prose lines often have none of the seed
			// characters, so skipping them up front saves repeated O(n) work.
			if !line.contains(":") && !line.contains(";")
				&& !line.contains("8") && !line.contains("=") {
				output.append(line); continue
			}
			output.append(processLine(line))
		}
		return output.joined(separator: "\n")
	}

	/// Per-line variant used by `MarkdownPreprocessor.mergedLinePass`.
	static func applyLine(_ line: String) -> String {
		if !line.contains(":") && !line.contains(";")
			&& !line.contains("8") && !line.contains("=") {
			return line
		}
		return processLine(line)
	}

	private static func processLine(_ line: String) -> String {
		var result = ""
		var i = line.startIndex
		while i < line.endIndex {
			let ch = line[i]
			if ch == "`" {
				if let close = line[line.index(after: i)...].firstIndex(of: "`") {
					result.append(contentsOf: line[i...close])
					i = line.index(after: close); continue
				}
			}
			if isWordBoundary(before: i, in: line),
			   let (emoji, after) = matchEmoticon(at: i, in: line),
			   isWordBoundary(at: after, in: line) {
				result.append(emoji)
				i = after; continue
			}
			result.append(ch)
			i = line.index(after: i)
		}
		return result
	}

	private static func isWordBoundary(before i: String.Index, in line: String) -> Bool {
		if i == line.startIndex { return true }
		let prev = line[line.index(before: i)]
		return prev.isWhitespace || prev == "(" || prev == "["
	}

	private static func isWordBoundary(at i: String.Index, in line: String) -> Bool {
		if i == line.endIndex { return true }
		let ch = line[i]
		return ch.isWhitespace || ch == "." || ch == "," || ch == "!" || ch == "?" || ch == ")" || ch == "]"
	}

	/// Returns the emoji + the index past the emoticon if `i` opens one.
	/// Tries longest-match-first ordering so `:-)` wins over `:-`.
	private static func matchEmoticon(at i: String.Index, in line: String) -> (String, String.Index)? {
		for (token, emoji) in tokens {
			guard let end = line.index(i, offsetBy: token.count, limitedBy: line.endIndex) else { continue }
			if line[i..<end] == Substring(token) { return (emoji, end) }
		}
		return nil
	}

	// Ordered so longer tokens match before their prefixes.
	private static let tokens: [(String, String)] = [
		(":-)", "🙂"),
		(":-(", "🙁"),
		(":-D", "😄"),
		(":-P", "😛"),
		(":-p", "😛"),
		(":-O", "😮"),
		(":-o", "😮"),
		(":-|", "😐"),
		(":-/", "😕"),
		(":'(", "😢"),
		("8-)", "😎"),
		(";-)", "😉"),
		(":)",  "🙂"),
		(":(",  "🙁"),
		(":D",  "😄"),
		(":P",  "😛"),
		(":p",  "😛"),
		(":O",  "😮"),
		(":o",  "😮"),
		(":|",  "😐"),
		(":/",  "😕"),
		(";)",  "😉"),
		("=)",  "🙂"),
	]
}
