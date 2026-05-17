//
//  SmartTypography.swift
//  MarkDownRange
//

import Foundation

/// Converts ASCII typographic shortcuts to their proper Unicode forms:
/// `(c)`/`(C)` → ©, `(r)`/`(R)` → ®, `(tm)`/`(TM)` → ™, `(p)`/`(P)` → ℗, `+-` → ±,
/// and three-or-more consecutive periods → `…` (with any trailing extras kept).
/// Skips fenced code blocks and inline code spans so source snippets aren't
/// silently rewritten.
public enum SmartTypography {
	public static func process(_ text: String) -> String {
		guard needsProcessing(text) else { return text }
		var output: [String] = []
		var inFence = false
		for line in text.components(separatedBy: "\n") {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
				inFence.toggle()
				output.append(line); continue
			}
			if inFence { output.append(line); continue }
			if isStructuralDashLine(trimmed) { output.append(line); continue }
			output.append(processLine(line))
		}
		return output.joined(separator: "\n")
	}

	/// Markdown reserves whole lines of `-`, `=`, `_`, `*`, and the
	/// `|---|:---:|` table-delimiter form for structural meaning (thematic
	/// breaks, setext headings, table separators). Converting their dashes to
	/// en/em dashes destroys those constructs, so skip the line entirely when
	/// it looks like one of them.
	private static func isStructuralDashLine(_ trimmed: String) -> Bool {
		guard !trimmed.isEmpty else { return false }
		// Thematic break / setext underline: only `-`, `=`, `_`, `*`, spaces.
		let breakChars: Set<Character> = ["-", "=", "_", "*", " ", "\t"]
		if trimmed.allSatisfy({ breakChars.contains($0) }),
		   trimmed.contains(where: { $0 == "-" || $0 == "=" }) {
			return true
		}
		// Table delimiter row: `|`, `-`, `:`, spaces.
		let tableChars: Set<Character> = ["|", "-", ":", " ", "\t"]
		if trimmed.contains("|"),
		   trimmed.contains("-"),
		   trimmed.allSatisfy({ tableChars.contains($0) }) {
			return true
		}
		return false
	}

	private static func needsProcessing(_ text: String) -> Bool {
		text.contains("(") || text.contains("+-") || text.contains("...") || text.contains("--")
	}

	private static func processLine(_ line: String) -> String {
		var result = ""
		var i = line.startIndex
		while i < line.endIndex {
			let ch = line[i]
			// Skip inline code spans verbatim — back through to the matching backtick.
			if ch == "`" {
				if let close = line[line.index(after: i)...].firstIndex(of: "`") {
					result.append(contentsOf: line[i...close])
					i = line.index(after: close); continue
				}
			}
			if let (replacement, after) = replacement(at: i, in: line) {
				result.append(replacement)
				i = after; continue
			}
			result.append(ch)
			i = line.index(after: i)
		}
		return result
	}

	/// Try to consume a typography token starting at `i`. Returns the replacement
	/// plus the index past the consumed characters.
	private static func replacement(at i: String.Index, in line: String) -> (String, String.Index)? {
		let ch = line[i]
		if ch == "(" {
			return parenToken(at: i, in: line)
		}
		if ch == "+", line.index(after: i) < line.endIndex, line[line.index(after: i)] == "-" {
			return ("±", line.index(i, offsetBy: 2))
		}
		if ch == "." {
			return ellipsis(at: i, in: line)
		}
		if ch == "-" {
			return dash(at: i, in: line)
		}
		return nil
	}

	private static func parenToken(at i: String.Index, in line: String) -> (String, String.Index)? {
		guard let close = line[line.index(after: i)...].firstIndex(of: ")") else { return nil }
		let inner = line[line.index(after: i)..<close].lowercased()
		let after = line.index(after: close)
		switch inner {
		case "c":  return ("©", after)
		case "r":  return ("®", after)
		case "tm": return ("™", after)
		case "p":  return ("℗", after)
		default:   return nil
		}
	}

	/// Collapse a run of 3+ periods into `…`, preserving any extra periods
	/// beyond the first three. Leaves runs of 1 or 2 periods alone.
	private static func ellipsis(at i: String.Index, in line: String) -> (String, String.Index)? {
		var count = 0
		var j = i
		while j < line.endIndex, line[j] == "." {
			count += 1
			j = line.index(after: j)
		}
		guard count >= 3 else { return nil }
		let extras = String(repeating: ".", count: count - 3)
		return ("…" + extras, j)
	}

	/// `---` → em-dash, `--` → en-dash. Longer runs collapse to a single dash
	/// of the appropriate length plus the leftover hyphens (matching the
	/// general "extras kept" rule the ellipsis uses).
	private static func dash(at i: String.Index, in line: String) -> (String, String.Index)? {
		var count = 0
		var j = i
		while j < line.endIndex, line[j] == "-" {
			count += 1
			j = line.index(after: j)
		}
		guard count >= 2 else { return nil }
		if count >= 3 {
			let extras = String(repeating: "-", count: count - 3)
			return ("—" + extras, j)
		}
		return ("–", j)
	}
}
