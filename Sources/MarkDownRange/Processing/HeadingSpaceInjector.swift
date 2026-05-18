//
//  HeadingSpaceInjector.swift
//  MarkDownRange
//

import Foundation

/// Inserts the missing space between a leading run of `#` characters and the
/// heading text so lenient writers (`##Heading`) still parse as a heading
/// under the CommonMark engine, which would otherwise treat the line as a
/// paragraph. Only runs when `MarkdownOptions.headingsRequireSpaceAfterHash`
/// is `false`. Skips fenced code blocks so source listings aren't rewritten.
enum HeadingSpaceInjector {
	static func process(_ text: String) -> String {
		guard text.contains("#") else { return text }
		var output: [String] = []
		var inFence = false
		for line in text.components(separatedBy: "\n") {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
				inFence.toggle()
				output.append(line); continue
			}
			if inFence { output.append(line); continue }
			output.append(injectSpace(into: line))
		}
		return output.joined(separator: "\n")
	}

	private static func injectSpace(into line: String) -> String {
		// Preserve any leading indentation — `   ##Heading` is still a
		// candidate up to three spaces of indent under CommonMark.
		var i = line.startIndex
		var leadingSpaces = 0
		while i < line.endIndex, line[i] == " ", leadingSpaces < 3 {
			leadingSpaces += 1
			i = line.index(after: i)
		}
		guard i < line.endIndex, line[i] == "#" else { return line }
		// Count `#` characters (1–6 max for headings).
		var hashCount = 0
		var hashEnd = i
		while hashEnd < line.endIndex, line[hashEnd] == "#", hashCount < 6 {
			hashCount += 1
			hashEnd = line.index(after: hashEnd)
		}
		// If hashes go beyond 6, this isn't a heading at all.
		if hashEnd < line.endIndex, line[hashEnd] == "#" { return line }
		// If we already have a space, tab, or end-of-line after the hashes, nothing to do.
		if hashEnd == line.endIndex { return line }
		let next = line[hashEnd]
		if next == " " || next == "\t" { return line }
		// Insert a space between the trailing `#` and the body text.
		let prefix = String(line[line.startIndex..<hashEnd])
		let suffix = String(line[hashEnd...])
		return prefix + " " + suffix
	}
}
