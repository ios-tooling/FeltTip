//
//  MarkdownInlineCodeToggle.swift
//  MarkDownRange
//
//  Produces a source-level inline-code toggle shared by the raw NSTextView
//  and the styled WKWebView bridge.
//

import Foundation

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

		let selected = text.substring(with: selection)
		let marker = String(repeating: "`", count: maxBacktickRun(in: selected) + 1)
		let markerLength = (marker as NSString).length
		let padding = needsPadding(selected) ? " " : ""
		let paddingLength = (padding as NSString).length
		return Change(
			range: selection,
			replacement: marker + padding + selected + padding + marker,
			selection: NSRange(
				location: selection.location + markerLength + paddingLength,
				length: selection.length))
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
		guard markerLength > 0 else { return nil }

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

	private static func needsPadding(_ string: String) -> Bool {
		guard !string.isEmpty else { return false }
		if string.hasPrefix("`") || string.hasSuffix("`") { return true }
		return string.hasPrefix(" ") && string.hasSuffix(" ")
			&& string.contains(where: { $0 != " " })
	}
}
