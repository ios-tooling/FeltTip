//
//  SuperSubProcessor.swift
//  MarkdownRendering
//

import Foundation

/// Converts `^text^` (superscript) and `~text~` (subscript) into Unicode where
/// every character maps cleanly, and falls back to `<sup>`/`<sub>` HTML tags
/// when any character is unmappable so the inline builder can render them via
/// baseline-offset styling. Skips fenced code blocks, inline code spans, and
/// `~~strikethrough~~` pairs so GFM extensions keep working.
public enum SuperSubProcessor {

	public static func process(_ text: String) -> String {
		MarkdownCodeProtection.transform(text) { processUnprotected($0) } ?? text
	}

	private static func processUnprotected(_ text: String) -> String {
		// Doc-level fast-fail: nothing to do if neither marker is present.
		guard text.contains("^") || text.contains("~") else { return text }
		var output: [String] = []
		var inFence = false
		for line in text.components(separatedBy: "\n") {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
				inFence.toggle()
				output.append(line); continue
			}
			if inFence { output.append(line); continue }
			// Per-line fast-fail: the char-by-char scan in `processLine` is the
			// expensive part. Skip lines that can't possibly contain a marker.
			if !line.contains("^") && !line.contains("~") { output.append(line); continue }
			output.append(processLine(line))
		}
		return output.joined(separator: "\n")
	}

	/// Per-line variant used by `MarkdownPreprocessor.mergedLinePass`. Bakes
	/// in the doc-level marker fast-fail so the merged pass doesn't need
	/// to know which lines are candidates.
	static func applyLine(_ line: String) -> String {
		if !line.contains("^") && !line.contains("~") { return line }
		return processLine(line)
	}

	private static func processLine(_ line: String) -> String {
		var pieces: [String] = []
		var pending = ""
		var i = line.startIndex
		while i < line.endIndex {
			let ch = line[i]
			if ch == "`" {
				if let close = line[line.index(after: i)...].firstIndex(of: "`") {
					if !pending.isEmpty { pieces.append(applyMarkers(pending)); pending = "" }
					pieces.append(String(line[i...close]))
					i = line.index(after: close); continue
				}
			}
			if let end = MarkdownCodeProtection.protectedInlineToken(in: line, at: i) {
				if !pending.isEmpty { pieces.append(applyMarkers(pending)); pending = "" }
				pieces.append(String(line[i..<end]))
				i = end; continue
			}
			// Pass HTML tags through verbatim. A `~` inside an attribute value
			// (e.g. a URL with `~user`) must not pair with another `~` elsewhere
			// on the line — that would mangle the tag into `<sub>` markup and
			// destroy the surrounding HTML structure.
			if ch == "<", let close = line[line.index(after: i)...].firstIndex(of: ">") {
				if !pending.isEmpty { pieces.append(applyMarkers(pending)); pending = "" }
				pieces.append(String(line[i...close]))
				i = line.index(after: close); continue
			}
			pending.append(ch)
			i = line.index(after: i)
		}
		if !pending.isEmpty { pieces.append(applyMarkers(pending)) }
		return pieces.joined()
	}

	private static func applyMarkers(_ segment: String) -> String {
		applySingleCharMarker(in: applySingleCharMarker(in: segment, marker: "^", map: superMap, tag: "sup"),
							  marker: "~", map: subMap, tag: "sub")
	}

	/// Walk `segment`, replacing isolated `<marker>text<marker>` pairs while
	/// leaving doubled markers (`^^` / `~~`) and code spans alone — Swift's
	/// `Regex` doesn't support lookbehind, so the manual scan is the only
	/// way to skip strikethrough's `~~` without splitting it open.
	private static func applySingleCharMarker(in segment: String, marker: Character, map: [Character: Character], tag: String) -> String {
		var result = ""
		var i = segment.startIndex
		while i < segment.endIndex {
			let ch = segment[i]
			guard ch == marker else {
				result.append(ch); i = segment.index(after: i); continue
			}
			let next = segment.index(after: i)
			// Doubled marker (strikethrough or `^^`): preserve verbatim.
			if next < segment.endIndex, segment[next] == marker {
				result.append(ch); result.append(segment[next])
				i = segment.index(after: next); continue
			}
			// Opening marker must be followed by a non-space, non-marker char.
			guard next < segment.endIndex,
				  !segment[next].isWhitespace,
				  segment[next] != marker,
				  let close = findClosingMarker(marker, after: next, in: segment) else {
				result.append(ch); i = next; continue
			}
			let content = String(segment[next..<close])
			result.append(convert(content, map: map) ?? "<\(tag)>\(content)</\(tag)>")
			i = segment.index(after: close)
		}
		return result
	}

	private static func findClosingMarker(_ marker: Character, after start: String.Index, in segment: String) -> String.Index? {
		var j = start
		while j < segment.endIndex {
			let ch = segment[j]
			if ch == marker {
				let after = segment.index(after: j)
				if after < segment.endIndex, segment[after] == marker { return nil } // hit a `~~`/`^^`, bail
				return j
			}
			j = segment.index(after: j)
		}
		return nil
	}

	private static func convert(_ text: String, map: [Character: Character]) -> String? {
		var result = ""
		for ch in text {
			guard let mapped = map[ch] else { return nil }
			result.append(mapped)
		}
		return result.isEmpty ? nil : result
	}

	private static let superMap: [Character: Character] = [
		"0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
		"5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
		"+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
		"a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ",
		"f": "ᶠ", "g": "ᵍ", "h": "ʰ", "i": "ⁱ", "j": "ʲ",
		"k": "ᵏ", "l": "ˡ", "m": "ᵐ", "n": "ⁿ", "o": "ᵒ",
		"p": "ᵖ", "r": "ʳ", "s": "ˢ", "t": "ᵗ", "u": "ᵘ",
		"v": "ᵛ", "w": "ʷ", "x": "ˣ", "y": "ʸ", "z": "ᶻ",
	]

	private static let subMap: [Character: Character] = [
		"0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
		"5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
		"+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
		"a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ",
		"k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ",
		"p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ",
		"v": "ᵥ", "x": "ₓ",
	]
}
