//
//  SmartTypography.swift
//  FeltTip
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

	/// Per-line variant used by `MarkdownPreprocessor.mergedLinePass`.
	static func applyLine(_ line: String) -> String {
		// `needsProcessing` is the same predicate the top-level `process`
		// uses; checking per-line lets us skip prose without the seed
		// substrings (`(`, `+-`, `...`, `--`).
		if !needsProcessing(line) { return line }
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		if isStructuralDashLine(trimmed) { return line }
		return processLine(line)
	}

	/// Byte-level twin of `applyLine` for pure-ASCII lines; `.notASCII` sends
	/// the caller to the general path. Mirrors `isStructuralDashLine`, the
	/// code-span and tag passthroughs, and every token rule.
	static func applyASCIILine(_ line: String) -> ASCIILineResult {
		applyASCIILine(Substring(line))
	}

	static func applyASCIILine(_ line: Substring) -> ASCIILineResult {
		var line = line
		return line.withUTF8 { bytes in
			guard ASCIIByte.allASCII(bytes) else { return .notASCII }
			if isStructuralDashLineASCII(bytes) { return .unchanged }
			var builder = ASCIILineBuilder(source: bytes)
			var i = 0
			while i < bytes.count {
				let b = bytes[i]
				if b == 0x60, let close = ASCIIByte.indexOf(0x60, in: bytes, after: i) {
					builder.keep(through: close + 1); i = close + 1; continue
				}
				if b == 0x3C, let close = ASCIIByte.indexOf(0x3E, in: bytes, after: i) {
					builder.keep(through: close + 1); i = close + 1; continue
				}
				if let (replacement, after) = replacementASCII(bytes, at: i) {
					builder.keep(through: i)
					builder.replace(through: after, with: replacement)
					i = after; continue
				}
				i += 1
			}
			return builder.finish()
		}
	}

	private static func isStructuralDashLineASCII(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
		var first = 0
		while first < bytes.count, bytes[first] == 0x20 || bytes[first] == 0x09 { first += 1 }
		var last = bytes.count
		while last > first, bytes[last - 1] == 0x20 || bytes[last - 1] == 0x09 { last -= 1 }
		guard last > first else { return false }
		var onlyBreak = true, hasDashOrEquals = false
		var onlyTable = true, hasPipe = false, hasDash = false
		for i in first..<last {
			let c = bytes[i]
			switch c {
			case 0x2D: hasDashOrEquals = true; hasDash = true
			case 0x3D: hasDashOrEquals = true; onlyTable = false
			case 0x5F, 0x2A: onlyTable = false
			case 0x20, 0x09: break
			case 0x7C: hasPipe = true; onlyBreak = false
			case 0x3A: onlyBreak = false
			default: onlyBreak = false; onlyTable = false
			}
		}
		if onlyBreak, hasDashOrEquals { return true }
		if hasPipe, hasDash, onlyTable { return true }
		return false
	}

	private static let copyright = Array("©".utf8), registered = Array("®".utf8)
	private static let trademark = Array("™".utf8), phonogram = Array("℗".utf8)
	private static let plusMinusSign = Array("±".utf8), ellipsisSign = Array("…".utf8)
	private static let emDash = Array("—".utf8), enDash = Array("–".utf8)

	private static func replacementASCII(
		_ bytes: UnsafeBufferPointer<UInt8>, at i: Int
	) -> ([UInt8], Int)? {
		let b = bytes[i]
		if b == 0x28 {
			guard let close = ASCIIByte.indexOf(0x29, in: bytes, after: i) else { return nil }
			let inner = bytes[(i + 1)..<close]
			let after = close + 1
			switch inner.count {
			case 1:
				switch inner[inner.startIndex] | 0x20 {
				case 0x63: return (copyright, after)
				case 0x72: return (registered, after)
				case 0x70: return (phonogram, after)
				default: return nil
				}
			case 2:
				if inner[inner.startIndex] | 0x20 == 0x74, inner[inner.startIndex + 1] | 0x20 == 0x6D {
					return (trademark, after)
				}
				return nil
			default: return nil
			}
		}
		if b == 0x2B, i + 1 < bytes.count, bytes[i + 1] == 0x2D {
			return (plusMinusSign, i + 2)
		}
		if b == 0x2E {
			var j = i
			while j < bytes.count, bytes[j] == 0x2E { j += 1 }
			guard j - i >= 3 else { return nil }
			return (ellipsisSign + Array(repeating: 0x2E, count: j - i - 3), j)
		}
		if b == 0x2D {
			var j = i
			while j < bytes.count, bytes[j] == 0x2D { j += 1 }
			let count = j - i
			guard count >= 2 else { return nil }
			if count >= 3 { return (emDash + Array(repeating: 0x2D, count: count - 3), j) }
			return (enDash, j)
		}
		return nil
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
			// Skip HTML tags and comments verbatim. Without this, `<!-- foo -->`
			// becomes `<!– foo –>` (en-dash), the CommonMark parser stops seeing
			// it as a type-2 HTML block, and the mangled text leaks into the
			// rendered output as a paragraph. Same single-line `<...>` skip that
			// SmartQuotes uses for attribute values.
			if ch == "<", let close = line[line.index(after: i)...].firstIndex(of: ">") {
				result.append(contentsOf: line[i...close])
				i = line.index(after: close); continue
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
