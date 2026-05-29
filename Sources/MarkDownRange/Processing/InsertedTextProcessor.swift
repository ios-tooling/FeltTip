//
//  InsertedTextProcessor.swift
//  MarkDownRange
//

import Foundation

/// CriticMarkup-style inserted text: `++Text++` becomes `<u>Text</u>` so the
/// inline builder picks it up via its existing `<u>` handler. Skips fenced
/// code blocks and inline code spans, and requires the content to start and
/// end with a non-space non-`+` character so things like `c++ test++` don't
/// get rewritten.
public enum InsertedTextProcessor {
	public static func process(_ text: String) -> String {
		guard text.contains("++") else { return text }
		var output: [String] = []
		var inFence = false
		for line in text.components(separatedBy: "\n") {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
				inFence.toggle()
				output.append(line); continue
			}
			if inFence { output.append(line); continue }
			output.append(processLine(line))
		}
		return output.joined(separator: "\n")
	}

	/// Per-line variant used by `MarkdownPreprocessor.mergedLinePass`.
	static func applyLine(_ line: String) -> String {
		if !line.contains("++") { return line }
		return processLine(line)
	}

	private static func processLine(_ line: String) -> String {
		guard line.contains("++") else { return line }
		var pieces: [String] = []
		var pending = ""
		var i = line.startIndex
		while i < line.endIndex {
			let ch = line[i]
			if ch == "`" {
				if let close = line[line.index(after: i)...].firstIndex(of: "`") {
					if !pending.isEmpty { pieces.append(replaceInPlain(pending)); pending = "" }
					pieces.append(String(line[i...close]))
					i = line.index(after: close); continue
				}
			}
			pending.append(ch)
			i = line.index(after: i)
		}
		if !pending.isEmpty { pieces.append(replaceInPlain(pending)) }
		return pieces.joined()
	}

	private static func replaceInPlain(_ segment: String) -> String {
		String(segment.replacing(/\+\+([^+\s](?:[^+]*[^+\s])?)\+\+/) { "<u>\($0.1)</u>" })
	}
}
