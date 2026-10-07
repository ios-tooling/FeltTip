//
//  EmoticonShortcodes.swift
//  FeltTip
//

import Foundation

/// Converts plain-text emoticons like `:-)` and `;)` into their emoji equivalents.
/// Skips fenced code blocks and inline code spans, and only matches emoticons
/// surrounded by whitespace (or at line boundaries) so we don't rewrite tokens
/// in URLs or identifiers.
public enum EmoticonShortcodes {
	public static func process(_ text: String) -> String {
		guard containsToken(in: text) else { return text }
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

	/// One document-wide regex search is materially cheaper than invoking the
	/// per-line scanner merely because ordinary prose contains a digit, colon,
	/// semicolon, or equals sign. The pattern is built from the exact supported
	/// spellings, so it cannot suppress a real replacement.
	static func containsToken(in text: String) -> Bool {
		tokenPattern.firstMatch(
			in: text,
			range: NSRange(text.startIndex..., in: text)
		) != nil
	}

	/// Per-line variant used by `MarkdownPreprocessor.mergedLinePass`.
	static func applyLine(_ line: String) -> String {
		// Every spelling starts with `:` `;` `8` or `=`. Check bytes: this is
		// the non-ASCII line path, and `String.contains` walks Characters.
		var hasSeed = false
		for b in line.utf8 where b == 0x3A || b == 0x3B || b == 0x38 || b == 0x3D {
			hasSeed = true
			break
		}
		return hasSeed ? processLine(line) : line
	}

	/// Byte-level twin of `applyLine` for pure-ASCII lines (`.notASCII`
	/// otherwise): code spans pass through, and a token is replaced only at a
	/// word boundary on both sides, longest spelling first.
	static func applyASCIILine(_ line: String) -> ASCIILineResult {
		applyASCIILine(Substring(line))
	}

	static func applyASCIILine(_ line: Substring) -> ASCIILineResult {
		var line = line
		return line.withUTF8 { bytes in
			guard ASCIIByte.allASCII(bytes) else { return .notASCII }
			var builder = ASCIILineBuilder(source: bytes)
			var i = 0
			while i < bytes.count {
				let b = bytes[i]
				if b == 0x60, let close = ASCIIByte.indexOf(0x60, in: bytes, after: i) {
					builder.keep(through: close + 1); i = close + 1; continue
				}
				// Every spelling starts with `:` `;` `8` or `=`; anything else
				// cannot open a token, so skip the 23-way match for it.
				if b == 0x3A || b == 0x3B || b == 0x38 || b == 0x3D,
				   isWordBoundaryBeforeASCII(bytes, i),
				   let (emoji, after) = matchEmoticonASCII(bytes, at: i),
				   isWordBoundaryAtASCII(bytes, after) {
					builder.keep(through: i)
					builder.replace(through: after, with: emoji)
					i = after; continue
				}
				i += 1
			}
			return builder.finish()
		}
	}

	private static func isWordBoundaryBeforeASCII(_ bytes: UnsafeBufferPointer<UInt8>, _ i: Int) -> Bool {
		guard i > 0 else { return true }
		let prev = bytes[i - 1]
		return ASCIIByte.isWhitespace(prev) || prev == 0x28 || prev == 0x5B
	}

	private static func isWordBoundaryAtASCII(_ bytes: UnsafeBufferPointer<UInt8>, _ i: Int) -> Bool {
		guard i < bytes.count else { return true }
		let c = bytes[i]
		return ASCIIByte.isWhitespace(c) || c == 0x2E || c == 0x2C || c == 0x21 || c == 0x3F || c == 0x29 || c == 0x5D
	}

	/// Spellings as bytes, in the same longest-first order as `tokens`.
	/// Every spelling is two or three bytes.
	private static let tokenBytes: [(first: UInt8, second: UInt8, third: UInt8?, emoji: [UInt8])] = tokens.map {
		let t = Array($0.0.utf8)
		return (t[0], t[1], t.count > 2 ? t[2] : nil, Array($0.1.utf8))
	}

	private static func matchEmoticonASCII(_ bytes: UnsafeBufferPointer<UInt8>, at i: Int) -> ([UInt8], Int)? {
		guard i + 1 < bytes.count else { return nil }
		let first = bytes[i], second = bytes[i + 1]
		let third: UInt8? = i + 2 < bytes.count ? bytes[i + 2] : nil
		for token in tokenBytes where token.first == first && token.second == second {
			if let needed = token.third {
				if third == needed { return (token.emoji, i + 3) }
			} else {
				return (token.emoji, i + 2)
			}
		}
		return nil
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

	private static let tokenPattern = try! NSRegularExpression(
		pattern: tokens
			.map { NSRegularExpression.escapedPattern(for: $0.0) }
			.joined(separator: "|")
	)
}
