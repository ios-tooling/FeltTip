//
//  MarkdownSourceFormatter.swift
//  MarkDownRange
//
//  Source-level formatting shared by the raw NSTextView and styled WKWebView.
//  All ranges and selections are UTF-16 so they can cross the AppKit/WebKit
//  bridge without conversion.
//

import Foundation

public enum MarkdownFormattingCommand: String, CaseIterable, Sendable {
	case bold
	case italic
	case underline
	case strikethrough
	case inlineCode
	case highlight
	case superscript
	case subscriptText = "subscript"
	case link
	case paragraph
	case heading1
	case heading2
	case heading3
	case heading4
	case heading5
	case heading6
	case increaseHeading
	case decreaseHeading
	case blockQuote
	case bulletedList
	case numberedList
	case taskList
	case horizontalRule

	var supportsCrossRunSelection: Bool {
		switch self {
		case .paragraph, .heading1, .heading2, .heading3, .heading4, .heading5,
			 .heading6, .increaseHeading, .decreaseHeading, .blockQuote,
			 .bulletedList, .numberedList, .taskList, .horizontalRule:
			true
		default:
			false
		}
	}
}

struct MarkdownSourceFormattingChange: Equatable {
	let range: NSRange
	let replacement: String
	let selection: NSRange
	/// A raw editor can place a caret inside Markdown syntax that the styled
	/// projection deliberately hides. Nil means both panes share `selection`.
	let rawSelection: NSRange?

	init(
		range: NSRange,
		replacement: String,
		selection: NSRange,
		rawSelection: NSRange? = nil
	) {
		self.range = range
		self.replacement = replacement
		self.selection = selection
		self.rawSelection = rawSelection
	}
}

enum MarkdownSourceFormatter {
	private struct Edit {
		let range: NSRange
		let replacement: String
	}

	private enum ListKind: Equatable {
		case bulleted
		case numbered
		case task
	}

	static func change(
		in source: String,
		selection: NSRange,
		command: MarkdownFormattingCommand
	) -> MarkdownSourceFormattingChange? {
		let text = source as NSString
		guard selection.location >= 0, selection.length >= 0,
			  selection.upperBound <= text.length else { return nil }

		switch command {
		case .bold:
			return toggleDelimited(in: text, selection: selection, marker: "**", alternates: ["__"])
		case .italic:
			return toggleDelimited(in: text, selection: selection, marker: "_", alternates: ["*"])
		case .underline:
			return toggleHTML(in: text, selection: selection, opening: "<u>", closing: "</u>")
		case .strikethrough:
			return toggleDelimited(in: text, selection: selection, marker: "~~")
		case .inlineCode:
			guard let change = MarkdownInlineCodeToggle.change(in: source, selection: selection) else { return nil }
			return .init(range: change.range, replacement: change.replacement, selection: change.selection)
		case .highlight:
			return toggleDelimited(in: text, selection: selection, marker: "==")
		case .superscript:
			return toggleDelimited(in: text, selection: selection, marker: "^")
		case .subscriptText:
			return toggleDelimited(in: text, selection: selection, marker: "~")
		case .link:
			return toggleLink(in: text, selection: selection)
		case .paragraph:
			return setHeading(in: text, selection: selection, level: 0)
		case .heading1:
			return setHeading(in: text, selection: selection, level: 1)
		case .heading2:
			return setHeading(in: text, selection: selection, level: 2)
		case .heading3:
			return setHeading(in: text, selection: selection, level: 3)
		case .heading4:
			return setHeading(in: text, selection: selection, level: 4)
		case .heading5:
			return setHeading(in: text, selection: selection, level: 5)
		case .heading6:
			return setHeading(in: text, selection: selection, level: 6)
		case .increaseHeading:
			return adjustHeading(in: text, selection: selection, delta: -1)
		case .decreaseHeading:
			return adjustHeading(in: text, selection: selection, delta: 1)
		case .blockQuote:
			return toggleBlockQuote(in: text, selection: selection)
		case .bulletedList:
			return toggleList(in: text, selection: selection, kind: .bulleted)
		case .numberedList:
			return toggleList(in: text, selection: selection, kind: .numbered)
		case .taskList:
			return toggleList(in: text, selection: selection, kind: .task)
		case .horizontalRule:
			return insertHorizontalRule(in: text, selection: selection)
		}
	}

	// MARK: Inline commands

	private static func toggleDelimited(
		in text: NSString,
		selection: NSRange,
		marker: String,
		alternates: [String] = []
	) -> MarkdownSourceFormattingChange {
		let selected = text.substring(with: selection)
		for candidate in [marker] + alternates {
			let length = (candidate as NSString).length
			guard selection.location >= length, selection.upperBound + length <= text.length else { continue }
			let before = text.substring(with: NSRange(location: selection.location - length, length: length))
			let after = text.substring(with: NSRange(location: selection.upperBound, length: length))
			if before == candidate, after == candidate {
				return .init(
					range: NSRange(
						location: selection.location - length,
						length: selection.length + length * 2),
					replacement: selected,
					selection: NSRange(location: selection.location - length, length: selection.length))
			}
		}

		// Toggling only the leading or trailing part of one delimited run
		// splits the run instead of stacking another pair of markers. Keep
		// horizontal boundary whitespace outside the surviving styled fragment
		// so the resulting Markdown remains valid.
		if selection.length > 0 {
			for candidate in [marker] + alternates {
				let length = (candidate as NSString).length
				let markerBefore = selection.location >= length &&
					text.substring(with: NSRange(
						location: selection.location - length, length: length)) == candidate
				let markerAfter = selection.upperBound + length <= text.length &&
					text.substring(with: NSRange(
						location: selection.upperBound, length: length)) == candidate

				if markerBefore, !markerAfter {
					var lineEnd = selection.upperBound
					while lineEnd < text.length {
						let character = text.character(at: lineEnd)
						if character == 0x0A || character == 0x0D { break }
						lineEnd += 1
					}
					let closing = text.range(
						of: candidate,
						options: [],
						range: NSRange(
							location: selection.upperBound,
							length: lineEnd - selection.upperBound))
					guard closing.location != NSNotFound else { continue }
					var remainderStart = selection.upperBound
					while remainderStart < closing.location {
						let character = text.character(at: remainderStart)
						guard character == 0x20 || character == 0x09 else { break }
						remainderStart += 1
					}
					guard remainderStart < closing.location else { continue }
					let selected = text.substring(with: selection)
					let whitespace = text.substring(with: NSRange(
						location: selection.upperBound,
						length: remainderStart - selection.upperBound))
					return .init(
						range: NSRange(
							location: selection.location - length,
							length: remainderStart - selection.location + length),
						replacement: selected + whitespace + candidate,
						selection: NSRange(
							location: selection.location - length,
							length: selection.length))
				}

				if markerAfter, !markerBefore {
					var lineStart = selection.location
					while lineStart > 0 {
						let character = text.character(at: lineStart - 1)
						if character == 0x0A || character == 0x0D { break }
						lineStart -= 1
					}
					let opening = text.range(
						of: candidate,
						options: .backwards,
						range: NSRange(
							location: lineStart,
							length: selection.location - lineStart))
					guard opening.location != NSNotFound else { continue }
					var prefixEnd = selection.location
					while prefixEnd > opening.upperBound {
						let character = text.character(at: prefixEnd - 1)
						guard character == 0x20 || character == 0x09 else { break }
						prefixEnd -= 1
					}
					guard prefixEnd > opening.upperBound else { continue }
					let whitespace = text.substring(with: NSRange(
						location: prefixEnd, length: selection.location - prefixEnd))
					let selected = text.substring(with: selection)
					return .init(
						range: NSRange(
							location: prefixEnd,
							length: selection.upperBound + length - prefixEnd),
						replacement: candidate + whitespace + selected,
						selection: NSRange(
							location: prefixEnd + length + (whitespace as NSString).length,
							length: selection.length))
				}
			}
		}

		let length = (marker as NSString).length
		return .init(
			range: selection,
			replacement: marker + selected + marker,
			selection: NSRange(location: selection.location + length, length: selection.length))
	}

	private static func toggleLink(
		in text: NSString,
		selection: NSRange
	) -> MarkdownSourceFormattingChange {
		func destinationClose(labelEnd: Int) -> Int? {
			guard labelEnd >= 0, labelEnd + 2 <= text.length,
			      text.substring(with: NSRange(location: labelEnd, length: 2)) == "]("
			else { return nil }
			var close = labelEnd + 2
			var nested = 0
			var escaped = false
			while close < text.length {
				let character = text.character(at: close)
				if escaped {
					escaped = false
				} else if character == 0x5C {
					escaped = true
				} else if character == 0x28 {
					nested += 1
				} else if character == 0x29, nested > 0 {
					nested -= 1
				} else if character == 0x29 {
					return close
				}
				if character == 0x0A || character == 0x0D { return nil }
				close += 1
			}
			return nil
		}

		let selected = text.substring(with: selection)
		if selection.location > 0,
		   text.substring(with: NSRange(location: selection.location - 1, length: 1)) == "[",
		   let close = destinationClose(labelEnd: selection.upperBound) {
			return .init(
				range: NSRange(
					location: selection.location - 1,
					length: close - selection.location + 2),
				replacement: selected,
				selection: NSRange(
					location: selection.location - 1, length: selection.length))
		}

		if selection.length > 0, selection.location > 0,
		   text.character(at: selection.location - 1) == 0x5B {
			var lineEnd = selection.upperBound
			while lineEnd < text.length {
				let character = text.character(at: lineEnd)
				if character == 0x0A || character == 0x0D { break }
				lineEnd += 1
			}
			let labelClose = text.range(
				of: "](",
				options: [],
				range: NSRange(
					location: selection.upperBound,
					length: lineEnd - selection.upperBound))
			if labelClose.location != NSNotFound,
			   destinationClose(labelEnd: labelClose.location) != nil {
				var remainderStart = selection.upperBound
				while remainderStart < labelClose.location {
					let character = text.character(at: remainderStart)
					guard character == 0x20 || character == 0x09 else { break }
					remainderStart += 1
				}
				if remainderStart < labelClose.location {
					let whitespace = text.substring(with: NSRange(
						location: selection.upperBound,
						length: remainderStart - selection.upperBound))
					return .init(
						range: NSRange(
							location: selection.location - 1,
							length: remainderStart - selection.location + 1),
						replacement: selected + whitespace + "[",
						selection: NSRange(
							location: selection.location - 1,
							length: selection.length))
				}
			}
		}

		if selection.length > 0 {
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
			let opening = text.range(
				of: "[",
				options: .backwards,
				range: NSRange(
					location: lineStart,
					length: selection.location - lineStart))
			let labelClose = text.range(
				of: "](",
				options: [],
				range: NSRange(
					location: selection.upperBound,
					length: lineEnd - selection.upperBound))
			if opening.location != NSNotFound,
			   labelClose.location != NSNotFound,
			   let close = destinationClose(labelEnd: labelClose.location) {
				var prefixEnd = selection.location
				while prefixEnd > opening.upperBound {
					let character = text.character(at: prefixEnd - 1)
					guard character == 0x20 || character == 0x09 else { break }
					prefixEnd -= 1
				}
				var suffixStart = selection.upperBound
				while suffixStart < labelClose.location {
					let character = text.character(at: suffixStart)
					guard character == 0x20 || character == 0x09 else { break }
					suffixStart += 1
				}
				if prefixEnd > opening.upperBound,
				   suffixStart < labelClose.location {
					let prefix = text.substring(with: NSRange(
						location: opening.location,
						length: prefixEnd - opening.location))
					let leadingWhitespace = text.substring(with: NSRange(
						location: prefixEnd,
						length: selection.location - prefixEnd))
					let trailingWhitespace = text.substring(with: NSRange(
						location: selection.upperBound,
						length: suffixStart - selection.upperBound))
					let suffix = text.substring(with: NSRange(
						location: suffixStart,
						length: labelClose.location - suffixStart))
					let destination = text.substring(with: NSRange(
						location: labelClose.location,
						length: close + 1 - labelClose.location))
					let replacement = prefix + destination + leadingWhitespace +
						selected + trailingWhitespace + "[" + suffix + destination
					return .init(
						range: NSRange(
							location: opening.location,
							length: close + 1 - opening.location),
						replacement: replacement,
						selection: NSRange(
							location: opening.location + (prefix as NSString).length +
								(destination as NSString).length +
								(leadingWhitespace as NSString).length,
							length: selection.length))
				}
			}
		}

		if selection.length > 0,
		   let close = destinationClose(labelEnd: selection.upperBound) {
			var lineStart = selection.location
			while lineStart > 0 {
				let character = text.character(at: lineStart - 1)
				if character == 0x0A || character == 0x0D { break }
				lineStart -= 1
			}
			let opening = text.range(
				of: "[",
				options: .backwards,
				range: NSRange(
					location: lineStart,
					length: selection.location - lineStart))
			if opening.location != NSNotFound {
				var prefixEnd = selection.location
				while prefixEnd > opening.upperBound {
					let character = text.character(at: prefixEnd - 1)
					guard character == 0x20 || character == 0x09 else { break }
					prefixEnd -= 1
				}
				if prefixEnd > opening.upperBound {
					let destination = text.substring(with: NSRange(
						location: selection.upperBound,
						length: close + 1 - selection.upperBound))
					let whitespace = text.substring(with: NSRange(
						location: prefixEnd,
						length: selection.location - prefixEnd))
					return .init(
						range: NSRange(
							location: prefixEnd, length: close + 1 - prefixEnd),
						replacement: destination + whitespace + selected,
						selection: NSRange(
							location: prefixEnd + (destination as NSString).length +
								(whitespace as NSString).length,
							length: selection.length))
				}
			}
		}

		let label = selected.isEmpty ? "link text" : selected
		let replacement = "[\(label)]()"
		return .init(
			range: selection,
			replacement: replacement,
			// The styled editor deliberately cannot place a caret inside hidden
			// Markdown syntax. Keep/select the visible label so both panes have
			// a valid post-command selection.
			selection: NSRange(
				location: selection.location + 1,
				length: (label as NSString).length),
			rawSelection: NSRange(
				location: selection.location + (label as NSString).length + 3,
				length: 0))
	}

	private static func toggleHTML(
		in text: NSString,
		selection: NSRange,
		opening: String,
		closing: String
	) -> MarkdownSourceFormattingChange {
		let openingLength = (opening as NSString).length
		let closingLength = (closing as NSString).length
		let selected = text.substring(with: selection)
		if selection.location >= openingLength,
		   selection.upperBound + closingLength <= text.length,
		   text.substring(with: NSRange(
				location: selection.location - openingLength,
				length: openingLength)) == opening,
		   text.substring(with: NSRange(
				location: selection.upperBound,
				length: closingLength)) == closing {
			return .init(
				range: NSRange(
					location: selection.location - openingLength,
					length: openingLength + selection.length + closingLength),
				replacement: selected,
				selection: NSRange(
					location: selection.location - openingLength,
					length: selection.length))
		}
		if selection.length > 0 {
			let openingBefore = selection.location >= openingLength &&
				text.substring(with: NSRange(
					location: selection.location - openingLength,
					length: openingLength)).caseInsensitiveCompare(opening) == .orderedSame
			let closingAfter = selection.upperBound + closingLength <= text.length &&
				text.substring(with: NSRange(
					location: selection.upperBound,
					length: closingLength)).caseInsensitiveCompare(closing) == .orderedSame

			if openingBefore, !closingAfter {
				var lineEnd = selection.upperBound
				while lineEnd < text.length {
					let character = text.character(at: lineEnd)
					if character == 0x0A || character == 0x0D { break }
					lineEnd += 1
				}
				let closingRange = text.range(
					of: closing,
					options: .caseInsensitive,
					range: NSRange(
						location: selection.upperBound,
						length: lineEnd - selection.upperBound))
				if closingRange.location != NSNotFound {
					var remainderStart = selection.upperBound
					while remainderStart < closingRange.location {
						let character = text.character(at: remainderStart)
						guard character == 0x20 || character == 0x09 else { break }
						remainderStart += 1
					}
					if remainderStart < closingRange.location {
						let whitespace = text.substring(with: NSRange(
							location: selection.upperBound,
							length: remainderStart - selection.upperBound))
						return .init(
							range: NSRange(
								location: selection.location - openingLength,
								length: remainderStart - selection.location + openingLength),
							replacement: selected + whitespace + opening,
							selection: NSRange(
								location: selection.location - openingLength,
								length: selection.length))
					}
				}
			}

			if closingAfter, !openingBefore {
				var lineStart = selection.location
				while lineStart > 0 {
					let character = text.character(at: lineStart - 1)
					if character == 0x0A || character == 0x0D { break }
					lineStart -= 1
				}
				let openingRange = text.range(
					of: opening,
					options: [.backwards, .caseInsensitive],
					range: NSRange(
						location: lineStart,
						length: selection.location - lineStart))
				if openingRange.location != NSNotFound {
					var prefixEnd = selection.location
					while prefixEnd > openingRange.upperBound {
						let character = text.character(at: prefixEnd - 1)
						guard character == 0x20 || character == 0x09 else { break }
						prefixEnd -= 1
					}
					if prefixEnd > openingRange.upperBound {
						let whitespace = text.substring(with: NSRange(
							location: prefixEnd,
							length: selection.location - prefixEnd))
						return .init(
							range: NSRange(
								location: prefixEnd,
								length: selection.upperBound + closingLength - prefixEnd),
							replacement: closing + whitespace + selected,
							selection: NSRange(
								location: prefixEnd + closingLength +
									(whitespace as NSString).length,
								length: selection.length))
					}
				}
			}
		}
		return .init(
			range: selection,
			replacement: opening + selected + closing,
			selection: NSRange(
				location: selection.location + openingLength,
				length: selection.length))
	}

	// MARK: Line commands

	private static func setHeading(
		in text: NSString,
		selection: NSRange,
		level: Int
	) -> MarkdownSourceFormattingChange? {
		let lines = selectedLineRanges(in: text, selection: selection)
		var edits: [Edit] = []
		for lineRange in lines {
			let line = text.substring(with: contentRange(of: lineRange, in: text)) as NSString
			let indent = leadingIndentLength(in: line)
			let heading = headingPrefixRange(in: line, after: indent)
			if line.length == indent, selection.length > 0 { continue }
			let replacement = level == 0 ? "" : String(repeating: "#", count: level) + " "
			let absolute = NSRange(
				location: lineRange.location + (heading?.location ?? indent),
				length: heading?.length ?? 0)
			if text.substring(with: absolute) != replacement {
				edits.append(.init(range: absolute, replacement: replacement))
			}
		}
		return formattingChange(in: text, selection: selection, edits: edits)
	}

	private static func adjustHeading(
		in text: NSString,
		selection: NSRange,
		delta: Int
	) -> MarkdownSourceFormattingChange? {
		let lines = selectedLineRanges(in: text, selection: selection)
		var edits: [Edit] = []
		for lineRange in lines {
			let line = text.substring(with: contentRange(of: lineRange, in: text)) as NSString
			let indent = leadingIndentLength(in: line)
			let heading = headingPrefixRange(in: line, after: indent)
			let current = heading.map { max(1, $0.length - 1) } ?? 0
			let next: Int
			if delta < 0 {
				next = current == 0 ? 1 : max(1, current - 1)
			} else {
				next = current == 0 ? 0 : current >= 6 ? 0 : current + 1
			}
			let replacement = next == 0 ? "" : String(repeating: "#", count: next) + " "
			let absolute = NSRange(
				location: lineRange.location + (heading?.location ?? indent),
				length: heading?.length ?? 0)
			if text.substring(with: absolute) != replacement {
				edits.append(.init(range: absolute, replacement: replacement))
			}
		}
		return formattingChange(in: text, selection: selection, edits: edits)
	}

	private static func toggleBlockQuote(
		in text: NSString,
		selection: NSRange
	) -> MarkdownSourceFormattingChange? {
		let lines = selectedLineRanges(in: text, selection: selection)
		let candidates = lines.filter {
			let content = contentRange(of: $0, in: text)
			return content.length > 0 || selection.length == 0
		}
		let allQuoted = !candidates.isEmpty && candidates.allSatisfy { lineRange in
			let line = text.substring(with: contentRange(of: lineRange, in: text)) as NSString
			return blockQuotePrefixRange(in: line, after: leadingIndentLength(in: line)) != nil
		}
		let edits = candidates.map { lineRange -> Edit in
			let line = text.substring(with: contentRange(of: lineRange, in: text)) as NSString
			let indent = leadingIndentLength(in: line)
			let existing = blockQuotePrefixRange(in: line, after: indent)
			let relative = existing ?? NSRange(location: indent, length: 0)
			return .init(
				range: NSRange(location: lineRange.location + relative.location, length: relative.length),
				replacement: allQuoted ? "" : "> ")
		}
		return formattingChange(in: text, selection: selection, edits: edits)
	}

	private static func toggleList(
		in text: NSString,
		selection: NSRange,
		kind: ListKind
	) -> MarkdownSourceFormattingChange? {
		let lines = selectedLineRanges(in: text, selection: selection)
		let candidates = lines.filter {
			let content = contentRange(of: $0, in: text)
			return content.length > 0 || selection.length == 0
		}
		let allTarget = !candidates.isEmpty && candidates.allSatisfy { lineRange in
			let line = text.substring(with: contentRange(of: lineRange, in: text)) as NSString
			let indent = leadingIndentLength(in: line)
			return listPrefix(in: line, after: indent)?.kind == kind
		}
		var ordinal = 1
		let edits = candidates.map { lineRange -> Edit in
			let line = text.substring(with: contentRange(of: lineRange, in: text)) as NSString
			let indent = leadingIndentLength(in: line)
			let existing = listPrefix(in: line, after: indent)
			let relative = existing?.range ?? NSRange(location: indent, length: 0)
			let replacement: String
			if allTarget {
				replacement = ""
			} else {
				switch kind {
				case .bulleted: replacement = "- "
				case .numbered:
					replacement = "\(ordinal). "
					ordinal += 1
				case .task: replacement = "- [ ] "
				}
			}
			return .init(
				range: NSRange(location: lineRange.location + relative.location, length: relative.length),
				replacement: replacement)
		}
		return formattingChange(in: text, selection: selection, edits: edits)
	}

	private static func insertHorizontalRule(
		in text: NSString,
		selection: NSRange
	) -> MarkdownSourceFormattingChange {
		// A rule is a block, never split the word under a collapsed caret.
		// Insert after the selected/current line and surround the rule with the
		// blank line CommonMark requires when another block follows.
		let insertion = selectedLineRanges(in: text, selection: selection)
			.last?.upperBound ?? selection.upperBound
		let needsLeadingNewline = insertion > 0 && text.character(at: insertion - 1) != 0x0A
		let needsTrailingNewline = insertion < text.length && text.character(at: insertion) != 0x0A
		let replacement = (needsLeadingNewline ? "\n" : "") + "---\n" + (needsTrailingNewline ? "\n" : "")
		return .init(
			range: NSRange(location: insertion, length: 0),
			replacement: replacement,
			selection: NSRange(location: insertion + (replacement as NSString).length, length: 0))
	}

	// MARK: Line parsing and selection mapping

	private static func selectedLineRanges(in text: NSString, selection: NSRange) -> [NSRange] {
		let start = min(selection.location, text.length)
		let inclusiveEnd = selection.length == 0
			? start
			: max(start, min(text.length, selection.upperBound) - 1)
		let total = text.lineRange(for: NSRange(location: start, length: inclusiveEnd - start))
		var result: [NSRange] = []
		var cursor = total.location
		while cursor < total.upperBound {
			let line = text.lineRange(for: NSRange(location: cursor, length: 0))
			result.append(line)
			let next = line.upperBound
			if next <= cursor { break }
			cursor = next
		}
		if result.isEmpty {
			result.append(NSRange(location: start, length: 0))
		}
		return result
	}

	private static func contentRange(of lineRange: NSRange, in text: NSString) -> NSRange {
		var length = lineRange.length
		while length > 0 {
			let character = text.character(at: lineRange.location + length - 1)
			guard character == 0x0A || character == 0x0D else { break }
			length -= 1
		}
		return NSRange(location: lineRange.location, length: length)
	}

	private static func leadingIndentLength(in line: NSString) -> Int {
		var index = 0
		while index < line.length {
			let character = line.character(at: index)
			guard character == 0x20 || character == 0x09 else { break }
			index += 1
		}
		return index
	}

	private static func headingPrefixRange(in line: NSString, after indent: Int) -> NSRange? {
		var cursor = indent
		while cursor < line.length, line.character(at: cursor) == 0x23, cursor - indent < 6 {
			cursor += 1
		}
		guard cursor > indent, cursor < line.length else { return nil }
		let separator = line.character(at: cursor)
		guard separator == 0x20 || separator == 0x09 else { return nil }
		while cursor < line.length {
			let character = line.character(at: cursor)
			guard character == 0x20 || character == 0x09 else { break }
			cursor += 1
		}
		return NSRange(location: indent, length: cursor - indent)
	}

	private static func blockQuotePrefixRange(in line: NSString, after indent: Int) -> NSRange? {
		guard indent < line.length, line.character(at: indent) == 0x3E else { return nil }
		let length = indent + 1 < line.length && line.character(at: indent + 1) == 0x20 ? 2 : 1
		return NSRange(location: indent, length: length)
	}

	private static func listPrefix(
		in line: NSString,
		after indent: Int
	) -> (kind: ListKind, range: NSRange)? {
		guard indent < line.length else { return nil }
		let first = line.character(at: indent)
		if first == 0x2D || first == 0x2B || first == 0x2A {
			var cursor = indent + 1
			guard cursor < line.length, isHorizontalSpace(line.character(at: cursor)) else { return nil }
			while cursor < line.length, isHorizontalSpace(line.character(at: cursor)) { cursor += 1 }
			if cursor + 2 < line.length, line.character(at: cursor) == 0x5B,
			   line.character(at: cursor + 2) == 0x5D {
				let state = line.character(at: cursor + 1)
				if state == 0x20 || state == 0x78 || state == 0x58 {
					cursor += 3
					guard cursor < line.length, isHorizontalSpace(line.character(at: cursor)) else { return nil }
					while cursor < line.length, isHorizontalSpace(line.character(at: cursor)) { cursor += 1 }
					return (.task, NSRange(location: indent, length: cursor - indent))
				}
			}
			return (.bulleted, NSRange(location: indent, length: cursor - indent))
		}

		var cursor = indent
		while cursor < line.length, line.character(at: cursor) >= 0x30,
			  line.character(at: cursor) <= 0x39 {
			cursor += 1
		}
		guard cursor > indent, cursor < line.length,
			  line.character(at: cursor) == 0x2E || line.character(at: cursor) == 0x29 else { return nil }
		cursor += 1
		guard cursor < line.length, isHorizontalSpace(line.character(at: cursor)) else { return nil }
		while cursor < line.length, isHorizontalSpace(line.character(at: cursor)) { cursor += 1 }
		return (.numbered, NSRange(location: indent, length: cursor - indent))
	}

	private static func isHorizontalSpace(_ character: unichar) -> Bool {
		character == 0x20 || character == 0x09
	}

	private static func formattingChange(
		in text: NSString,
		selection: NSRange,
		edits: [Edit]
	) -> MarkdownSourceFormattingChange? {
		let edits = edits
			.filter { text.substring(with: $0.range) != $0.replacement }
			.sorted { $0.range.location < $1.range.location }
		guard let first = edits.first, let last = edits.last else { return nil }
		for pair in zip(edits, edits.dropFirst()) where pair.0.range.upperBound > pair.1.range.location {
			return nil
		}

		let range = NSRange(
			location: first.range.location,
			length: last.range.upperBound - first.range.location)
		let replacement = NSMutableString(string: text.substring(with: range))
		for edit in edits.reversed() {
			let local = NSRange(
				location: edit.range.location - range.location,
				length: edit.range.length)
			replacement.replaceCharacters(in: local, with: edit.replacement)
		}

		let start = mapped(selection.location, through: edits)
		let end = mapped(selection.upperBound, through: edits)
		return .init(
			range: range,
			replacement: replacement as String,
			selection: NSRange(location: start, length: max(0, end - start)))
	}

	private static func mapped(_ offset: Int, through edits: [Edit]) -> Int {
		var delta = 0
		for edit in edits {
			let replacementLength = (edit.replacement as NSString).length
			if offset < edit.range.location { break }
			if offset >= edit.range.upperBound {
				delta += replacementLength - edit.range.length
				continue
			}
			return edit.range.location + delta + replacementLength
		}
		return offset + delta
	}
}
