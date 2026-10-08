//
//  MarkdownInlineCodeToggle.swift
//  FeltTip
//
//  Produces a source-level inline-code toggle shared by the raw NSTextView
//  and the styled WKWebView bridge.
//

import Foundation
import Markdown

enum MarkdownInlineCodeToggle {
	struct Change: Equatable {
		let range: NSRange
		let replacement: String
		let selection: NSRange
	}

	static func change(in source: String, selection: NSRange) -> Change? {
		let text = source as NSString
		guard selection.location >= 0, selection.length >= 0,
			  selection.upperBound <= text.length else { return nil }

		if let unwrapped = unwrap(text, selection: selection, padding: 0)
			?? unwrap(text, selection: selection, padding: 1) {
			return unwrapped
		}
		if let split = splitPartialSpan(text, selection: selection) {
			return split
		}

		let selected = text.substring(with: selection)
		let (replacement, markerLength, paddingLength) = wrapped(selected)
		// An adjacent literal closing backtick would merge with the new
		// delimiter. Escape it so its visible text remains outside the span.
		var end = selection.upperBound
		var suffix = ""
		if selection.length > 0 {
			// Do not turn a neighboring real code span's opening delimiter
			// into literal text. Leave this ambiguous boundary edit unchanged.
			if end < text.length, text.character(at: end) == 0x60,
			   startsCodeSpan(at: end, in: source) { return nil }
			while end < text.length, text.character(at: end) == 0x60 {
				suffix += "\\`"
				end += 1
			}
		}
		return Change(
			range: NSRange(location: selection.location, length: end - selection.location),
			replacement: replacement + suffix,
			selection: NSRange(
				location: selection.location + markerLength + paddingLength,
				length: selection.length))
	}

	private static func splitPartialSpan(
		_ text: NSString,
		selection: NSRange
	) -> Change? {
		guard selection.length > 0 else { return nil }
		var lineStart = selection.location
		while lineStart > 0 {
			let character = text.character(at: lineStart - 1)
			if character == 0x0A || character == 0x0D { break }
			lineStart -= 1
		}
		var lineEnd = selection.upperBound
		while lineEnd < text.length {
			let character = text.character(at: lineEnd)
			if character == 0x0A || character == 0x0D { break }
			lineEnd += 1
		}

		var runs: [NSRange] = []
		var scan = lineStart
		while scan < lineEnd {
			guard text.character(at: scan) == 0x60 else {
				scan += 1
				continue
			}
			let start = scan
			while scan < lineEnd, text.character(at: scan) == 0x60 { scan += 1 }
			runs.append(NSRange(location: start, length: scan - start))
		}

		var index = 0
		while index < runs.count {
			let opening = runs[index]
			if isEscaped(at: opening.location, in: text) {
				index += 1
				continue
			}
			guard let closingIndex = runs[(index + 1)...].firstIndex(where: {
				$0.length == opening.length
			}) else {
				index += 1
				continue
			}
			let closing = runs[closingIndex]
			defer { index = closingIndex + 1 }
			guard selection.location >= opening.upperBound,
			      selection.upperBound <= closing.location else { continue }

			var contentStart = opening.upperBound
			var contentEnd = closing.location
			if contentEnd - contentStart >= 2,
			   text.character(at: contentStart) == 0x20,
			   text.character(at: contentEnd - 1) == 0x20 {
				let raw = text.substring(with: NSRange(
					location: contentStart, length: contentEnd - contentStart))
				if raw.contains(where: { $0 != " " }) {
					contentStart += 1
					contentEnd -= 1
				}
			}
			guard selection.location >= contentStart,
			      selection.upperBound <= contentEnd else { continue }

			var prefixEnd = selection.location
			while prefixEnd > contentStart {
				let character = text.character(at: prefixEnd - 1)
				guard character == 0x20 || character == 0x09 else { break }
				prefixEnd -= 1
			}
			var suffixStart = selection.upperBound
			while suffixStart < contentEnd {
				let character = text.character(at: suffixStart)
				guard character == 0x20 || character == 0x09 else { break }
				suffixStart += 1
			}
			let prefix = text.substring(with: NSRange(
				location: contentStart, length: prefixEnd - contentStart))
			let leadingWhitespace = text.substring(with: NSRange(
				location: prefixEnd, length: selection.location - prefixEnd))
			let selected = text.substring(with: selection)
			let trailingWhitespace = text.substring(with: NSRange(
				location: selection.upperBound,
				length: suffixStart - selection.upperBound))
			let suffix = text.substring(with: NSRange(
				location: suffixStart, length: contentEnd - suffixStart))
			guard !prefix.isEmpty || !suffix.isEmpty else { return nil }

			let prefixWrapper = prefix.isEmpty ? "" : wrapped(prefix).replacement
			let suffixWrapper = suffix.isEmpty ? "" : wrapped(suffix).replacement
			return Change(
				range: NSRange(
					location: opening.location,
					length: closing.upperBound - opening.location),
				replacement: prefixWrapper + leadingWhitespace + selected +
					trailingWhitespace + suffixWrapper,
				selection: NSRange(
					location: opening.location + (prefixWrapper as NSString).length +
						(leadingWhitespace as NSString).length,
					length: selection.length))
		}
		return nil
	}

	private static func unwrap(_ text: NSString, selection: NSRange, padding: Int) -> Change? {
		let contentStart = selection.location
		let contentEnd = selection.upperBound
		guard contentStart >= padding, contentEnd + padding <= text.length else { return nil }
		if padding == 1 {
			guard text.character(at: contentStart - 1) == 0x20,
				  text.character(at: contentEnd) == 0x20 else { return nil }
		}

		var markerStart = contentStart - padding
		while markerStart > 0, text.character(at: markerStart - 1) == 0x60 {
			markerStart -= 1
		}
		let markerLength = contentStart - padding - markerStart
		guard markerLength > 0, !isEscaped(at: markerStart, in: text) else { return nil }
		var lineStart = markerStart
		while lineStart > 0 {
			let character = text.character(at: lineStart - 1)
			if character == 0x0A || character == 0x0D { break }
			lineStart -= 1
		}
		var priorMatchingRuns = 0
		var scan = lineStart
		while scan < markerStart {
			guard text.character(at: scan) == 0x60 else {
				scan += 1
				continue
			}
			let runStart = scan
			while scan < markerStart, text.character(at: scan) == 0x60 { scan += 1 }
			if scan - runStart == markerLength, priorMatchingRuns % 2 == 1 || !isEscaped(at: runStart, in: text) { priorMatchingRuns += 1 }
		}
		guard priorMatchingRuns % 2 == 0 else { return nil }

		var markerEnd = contentEnd + padding
		while markerEnd < text.length, text.character(at: markerEnd) == 0x60 {
			markerEnd += 1
		}
		guard markerEnd - contentEnd - padding == markerLength else { return nil }

		let selected = text.substring(with: selection)
		return Change(
			range: NSRange(location: markerStart, length: markerEnd - markerStart),
			replacement: selected,
			selection: NSRange(location: markerStart, length: selection.length))
	}

	private static func startsCodeSpan(at offset: Int, in source: String) -> Bool {
		let converter = SourceOffsetConverter(source)
		func walk(_ node: any Markup) -> Bool {
			if node is InlineCode, let range = node.range,
			   let span = converter.processedRange(
				lowerLine: range.lowerBound.line, lowerColumn: range.lowerBound.column,
				upperLine: range.upperBound.line, upperColumn: range.upperBound.column),
			   span.lowerBound == offset { return true }
			return node.children.contains { walk($0) }
		}
		return walk(Document(parsing: source, options: .disableSmartOpts))
	}

	private static func isEscaped(at offset: Int, in text: NSString) -> Bool {
		var cursor = offset
		while cursor > 0, text.character(at: cursor - 1) == 0x5C { cursor -= 1 }
		return (offset - cursor) % 2 == 1
	}

	private static func maxBacktickRun(in string: String) -> Int {
		var longest = 0
		var current = 0
		for character in string {
			if character == "`" {
				current += 1
				longest = max(longest, current)
			} else {
				current = 0
			}
		}
		return longest
	}

	private static func wrapped(_ string: String) -> (
		replacement: String,
		markerLength: Int,
		paddingLength: Int
	) {
		let marker = String(repeating: "`", count: maxBacktickRun(in: string) + 1)
		let padding = needsPadding(string) ? " " : ""
		return (
			marker + padding + string + padding + marker,
			(marker as NSString).length,
			(padding as NSString).length)
	}

	private static func needsPadding(_ string: String) -> Bool {
		guard !string.isEmpty else { return false }
		if string.hasPrefix("`") || string.hasSuffix("`") { return true }
		return string.hasPrefix(" ") && string.hasSuffix(" ")
			&& string.contains(where: { $0 != " " })
	}
}
