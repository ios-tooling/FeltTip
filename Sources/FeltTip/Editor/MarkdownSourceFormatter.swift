//
//  MarkdownSourceFormatter.swift
//  FeltTip
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

	private static func removingOuterWrapper(
		in text: NSString,
		opening: NSRange,
		closing: NSRange,
		selection: NSRange
	) -> MarkdownSourceFormattingChange {
		.init(
			range: NSRange(
				location: opening.location,
				length: closing.upperBound - opening.location),
			replacement: text.substring(with: NSRange(
				location: opening.upperBound,
				length: closing.location - opening.upperBound)),
			selection: NSRange(
				location: opening.location + selection.location - opening.upperBound,
				length: selection.length))
	}

	private static func inlineCodeContentRange(
		in text: NSString,
		wrapper: NSRange
	) -> NSRange? {
		guard wrapper.length >= 2,
		      text.character(at: wrapper.location) == 0x60 else { return nil }
		var openingEnd = wrapper.location
		while openingEnd < wrapper.upperBound,
		      text.character(at: openingEnd) == 0x60 { openingEnd += 1 }
		let markerLength = openingEnd - wrapper.location
		var scan = openingEnd
		while scan < wrapper.upperBound {
			guard text.character(at: scan) == 0x60 else {
				scan += 1
				continue
			}
			let runStart = scan
			while scan < wrapper.upperBound,
			      text.character(at: scan) == 0x60 { scan += 1 }
			guard scan - runStart != markerLength else {
				guard scan == wrapper.upperBound else { return nil }
				var contentStart = openingEnd
				var contentEnd = runStart
				if contentEnd - contentStart >= 2,
				   text.character(at: contentStart) == 0x20,
				   text.character(at: contentEnd - 1) == 0x20 {
					let raw = text.substring(with: NSRange(
						location: contentStart,
						length: contentEnd - contentStart))
					if raw.contains(where: { $0 != " " }) {
						contentStart += 1
						contentEnd -= 1
					}
				}
				return NSRange(
					location: contentStart,
					length: contentEnd - contentStart)
			}
		}
		return nil
	}

	private static func inlineLinkParts(
		in text: NSString,
		wrapper: NSRange
	) -> (label: NSRange, destination: String)? {
		guard wrapper.length >= 4,
		      text.character(at: wrapper.location) == 0x5B else { return nil }
		var depth = 0
		var escaped = false
		var labelClose: Int?
		var offset = wrapper.location
		while offset < wrapper.upperBound {
			let character = text.character(at: offset)
			if escaped {
				escaped = false
			} else if character == 0x5C {
				escaped = true
			} else if character == 0x5B {
				depth += 1
			} else if character == 0x5D {
				depth -= 1
				if depth == 0 {
					labelClose = offset
					break
				}
			}
			offset += 1
		}
		guard let labelClose,
		      labelClose + 2 <= wrapper.upperBound,
		      text.substring(with: NSRange(location: labelClose, length: 2)) == "](" else {
			return nil
		}
		var destinationDepth = 0
		escaped = false
		offset = labelClose + 2
		while offset < wrapper.upperBound {
			let character = text.character(at: offset)
			if escaped {
				escaped = false
			} else if character == 0x5C {
				escaped = true
			} else if character == 0x28 {
				destinationDepth += 1
			} else if character == 0x29, destinationDepth > 0 {
				destinationDepth -= 1
			} else if character == 0x29 {
				guard offset + 1 == wrapper.upperBound else { return nil }
				return (
					label: NSRange(
						location: wrapper.location + 1,
						length: labelClose - wrapper.location - 1),
					destination: text.substring(with: NSRange(
						location: labelClose,
						length: offset + 1 - labelClose)))
			}
			offset += 1
		}
		return nil
	}

	private static func inlineUnderlineParts(
		in text: NSString,
		wrapper: NSRange
	) -> (content: NSRange, opening: String, closing: String)? {
		let openingLength = 3
		let closingLength = 4
		guard wrapper.length >= openingLength + closingLength,
		      text.substring(with: NSRange(
				location: wrapper.location,
				length: openingLength)).caseInsensitiveCompare("<u>") == .orderedSame,
		      text.substring(with: NSRange(
				location: wrapper.upperBound - closingLength,
				length: closingLength)).caseInsensitiveCompare("</u>") == .orderedSame else {
			return nil
		}
		return (
			content: NSRange(
				location: wrapper.location + openingLength,
				length: wrapper.length - openingLength - closingLength),
			opening: text.substring(with: NSRange(
				location: wrapper.location, length: openingLength)),
			closing: text.substring(with: NSRange(
				location: wrapper.upperBound - closingLength, length: closingLength)))
	}

	private static func inlineSymmetricParts(
		in text: NSString,
		wrapper: NSRange
	) -> (content: NSRange, marker: String)? {
		for marker in ["~~", "==", "**", "__", "_", "*", "^", "~"] {
			let length = (marker as NSString).length
			guard wrapper.length >= length * 2 else { continue }
			if text.substring(with: NSRange(
				location: wrapper.location, length: length)) == marker,
			   text.substring(with: NSRange(
				location: wrapper.upperBound - length, length: length)) == marker {
				return (
					content: NSRange(
						location: wrapper.location + length,
						length: wrapper.length - length * 2),
					marker: marker)
			}
		}
		return nil
	}

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

		// Bold and italic share a three-character delimiter in combined runs.
		// Removing only one style from a partial selection must split the whole
		// triple-delimited run, then keep the complementary marker on the selected
		// text. Treating `**` or `*` independently leaves unbalanced delimiters.
		if selection.length > 0 {
			for candidate in [marker] + alternates {
				let candidateText = candidate as NSString
				guard candidateText.length == 1 || candidateText.length == 2 else { continue }
				let unit = candidateText.character(at: 0)
				guard (unit == 0x2A || unit == 0x5F),
				      (0..<candidateText.length).allSatisfy({
					candidateText.character(at: $0) == unit
				}) else { continue }

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

				var triples: [NSRange] = []
				var scan = lineStart
				while scan < lineEnd {
					guard text.character(at: scan) == unit else {
						scan += 1
						continue
					}
					let start = scan
					while scan < lineEnd, text.character(at: scan) == unit { scan += 1 }
					if scan - start == 3 {
						triples.append(NSRange(location: start, length: 3))
					}
				}

				var tripleIndex = 0
				while tripleIndex + 1 < triples.count {
					let opening = triples[tripleIndex]
					let closing = triples[tripleIndex + 1]
					tripleIndex += 2
					guard selection.location >= opening.upperBound,
					      selection.upperBound <= closing.location else { continue }
					let residualLength = 3 - candidateText.length
					let residual = String(
						repeating: Character(UnicodeScalar(unit)!), count: residualLength)
					let innerRange = NSRange(
						location: opening.upperBound,
						length: closing.location - opening.upperBound)
					if let codeContent = inlineCodeContentRange(in: text, wrapper: innerRange),
					   selection.location >= codeContent.location,
					   selection.upperBound <= codeContent.upperBound {
						if codeContent == selection {
							let inner = text.substring(with: innerRange)
							return .init(
								range: NSRange(
									location: opening.location,
									length: closing.upperBound - opening.location),
								replacement: residual + inner + residual,
								selection: NSRange(
									location: opening.location + residualLength +
										selection.location - opening.upperBound,
									length: selection.length))
						}
						var prefixEnd = selection.location
						while prefixEnd > codeContent.location {
							let character = text.character(at: prefixEnd - 1)
							guard character == 0x20 || character == 0x09 else { break }
							prefixEnd -= 1
						}
						var suffixStart = selection.upperBound
						while suffixStart < codeContent.upperBound {
							let character = text.character(at: suffixStart)
							guard character == 0x20 || character == 0x09 else { break }
							suffixStart += 1
						}
						let prefix = text.substring(with: NSRange(
							location: codeContent.location,
							length: prefixEnd - codeContent.location))
						let leadingWhitespace = text.substring(with: NSRange(
							location: prefixEnd,
							length: selection.location - prefixEnd))
						let trailingWhitespace = text.substring(with: NSRange(
							location: selection.upperBound,
							length: suffixStart - selection.upperBound))
						let suffix = text.substring(with: NSRange(
							location: suffixStart,
							length: codeContent.upperBound - suffixStart))
						if (!prefix.isEmpty || !suffix.isEmpty),
						   let selectedCode = MarkdownInlineCodeToggle.change(
							in: selected,
							selection: NSRange(
								location: 0, length: (selected as NSString).length)) {
							let prefixCode = prefix.isEmpty ? "" :
								MarkdownInlineCodeToggle.change(
									in: prefix,
									selection: NSRange(
										location: 0, length: (prefix as NSString).length))?.replacement ?? ""
							let suffixCode = suffix.isEmpty ? "" :
								MarkdownInlineCodeToggle.change(
									in: suffix,
									selection: NSRange(
										location: 0, length: (suffix as NSString).length))?.replacement ?? ""
							let openingMarker = text.substring(with: opening)
							let closingMarker = text.substring(with: closing)
							let prefixWrapper = prefix.isEmpty ? "" :
								openingMarker + prefixCode + closingMarker
							let suffixWrapper = suffix.isEmpty ? "" :
								openingMarker + suffixCode + closingMarker
							let selectedWrapper = residual + selectedCode.replacement + residual
							return .init(
								range: NSRange(
									location: opening.location,
									length: closing.upperBound - opening.location),
								replacement: prefixWrapper + leadingWhitespace + selectedWrapper +
									trailingWhitespace + suffixWrapper,
								selection: NSRange(
									location: opening.location + (prefixWrapper as NSString).length +
										(leadingWhitespace as NSString).length + residualLength +
										selectedCode.selection.location,
									length: selection.length))
						}
					}
					if let link = inlineLinkParts(in: text, wrapper: innerRange),
					   selection.location >= link.label.location,
					   selection.upperBound <= link.label.upperBound {
						if link.label == selection {
							let inner = text.substring(with: innerRange)
							return .init(
								range: NSRange(
									location: opening.location,
									length: closing.upperBound - opening.location),
								replacement: residual + inner + residual,
								selection: NSRange(
									location: opening.location + residualLength + 1,
									length: selection.length))
						}
						var prefixEnd = selection.location
						while prefixEnd > link.label.location {
							let character = text.character(at: prefixEnd - 1)
							guard character == 0x20 || character == 0x09 else { break }
							prefixEnd -= 1
						}
						var suffixStart = selection.upperBound
						while suffixStart < link.label.upperBound {
							let character = text.character(at: suffixStart)
							guard character == 0x20 || character == 0x09 else { break }
							suffixStart += 1
						}
						let prefix = text.substring(with: NSRange(
							location: link.label.location,
							length: prefixEnd - link.label.location))
						let leadingWhitespace = text.substring(with: NSRange(
							location: prefixEnd,
							length: selection.location - prefixEnd))
						let trailingWhitespace = text.substring(with: NSRange(
							location: selection.upperBound,
							length: suffixStart - selection.upperBound))
						let suffix = text.substring(with: NSRange(
							location: suffixStart,
							length: link.label.upperBound - suffixStart))
						let openingMarker = text.substring(with: opening)
						let closingMarker = text.substring(with: closing)
						let prefixWrapper = prefix.isEmpty ? "" :
							openingMarker + "[" + prefix + link.destination + closingMarker
						let selectedWrapper = residual + "[" + selected + link.destination + residual
						let suffixWrapper = suffix.isEmpty ? "" :
							openingMarker + "[" + suffix + link.destination + closingMarker
						return .init(
							range: NSRange(
								location: opening.location,
								length: closing.upperBound - opening.location),
							replacement: prefixWrapper + leadingWhitespace + selectedWrapper +
								trailingWhitespace + suffixWrapper,
							selection: NSRange(
								location: opening.location + (prefixWrapper as NSString).length +
									(leadingWhitespace as NSString).length + residualLength + 1,
								length: selection.length))
					}
					if let underline = inlineUnderlineParts(in: text, wrapper: innerRange),
					   selection.location >= underline.content.location,
					   selection.upperBound <= underline.content.upperBound {
						if underline.content == selection {
							let inner = text.substring(with: innerRange)
							return .init(
								range: NSRange(
									location: opening.location,
									length: closing.upperBound - opening.location),
								replacement: residual + inner + residual,
								selection: NSRange(
									location: opening.location + residualLength +
										(underline.opening as NSString).length,
									length: selection.length))
						}
						var prefixEnd = selection.location
						while prefixEnd > underline.content.location {
							let character = text.character(at: prefixEnd - 1)
							guard character == 0x20 || character == 0x09 else { break }
							prefixEnd -= 1
						}
						var suffixStart = selection.upperBound
						while suffixStart < underline.content.upperBound {
							let character = text.character(at: suffixStart)
							guard character == 0x20 || character == 0x09 else { break }
							suffixStart += 1
						}
						let prefix = text.substring(with: NSRange(
							location: underline.content.location,
							length: prefixEnd - underline.content.location))
						let leadingWhitespace = text.substring(with: NSRange(
							location: prefixEnd,
							length: selection.location - prefixEnd))
						let trailingWhitespace = text.substring(with: NSRange(
							location: selection.upperBound,
							length: suffixStart - selection.upperBound))
						let suffix = text.substring(with: NSRange(
							location: suffixStart,
							length: underline.content.upperBound - suffixStart))
						let openingMarker = text.substring(with: opening)
						let closingMarker = text.substring(with: closing)
						let prefixWrapper = prefix.isEmpty ? "" : openingMarker +
							underline.opening + prefix + underline.closing + closingMarker
						let selectedWrapper = residual + underline.opening + selected +
							underline.closing + residual
						let suffixWrapper = suffix.isEmpty ? "" : openingMarker +
							underline.opening + suffix + underline.closing + closingMarker
						return .init(
							range: NSRange(
								location: opening.location,
								length: closing.upperBound - opening.location),
							replacement: prefixWrapper + leadingWhitespace + selectedWrapper +
								trailingWhitespace + suffixWrapper,
							selection: NSRange(
								location: opening.location + (prefixWrapper as NSString).length +
									(leadingWhitespace as NSString).length + residualLength +
									(underline.opening as NSString).length,
								length: selection.length))
					}
					if let symmetric = inlineSymmetricParts(in: text, wrapper: innerRange),
					   selection.location >= symmetric.content.location,
					   selection.upperBound <= symmetric.content.upperBound {
						if symmetric.content == selection {
							let inner = text.substring(with: innerRange)
							return .init(
								range: NSRange(
									location: opening.location,
									length: closing.upperBound - opening.location),
								replacement: residual + inner + residual,
								selection: NSRange(
									location: opening.location + residualLength +
										(symmetric.marker as NSString).length,
									length: selection.length))
						}
						var prefixEnd = selection.location
						while prefixEnd > symmetric.content.location {
							let character = text.character(at: prefixEnd - 1)
							guard character == 0x20 || character == 0x09 else { break }
							prefixEnd -= 1
						}
						var suffixStart = selection.upperBound
						while suffixStart < symmetric.content.upperBound {
							let character = text.character(at: suffixStart)
							guard character == 0x20 || character == 0x09 else { break }
							suffixStart += 1
						}
						let prefix = text.substring(with: NSRange(
							location: symmetric.content.location,
							length: prefixEnd - symmetric.content.location))
						let leadingWhitespace = text.substring(with: NSRange(
							location: prefixEnd,
							length: selection.location - prefixEnd))
						let trailingWhitespace = text.substring(with: NSRange(
							location: selection.upperBound,
							length: suffixStart - selection.upperBound))
						let suffix = text.substring(with: NSRange(
							location: suffixStart,
							length: symmetric.content.upperBound - suffixStart))
						let openingMarker = text.substring(with: opening)
						let closingMarker = text.substring(with: closing)
						let prefixWrapper = prefix.isEmpty ? "" : openingMarker +
							symmetric.marker + prefix + symmetric.marker + closingMarker
						let selectedWrapper = residual + symmetric.marker + selected +
							symmetric.marker + residual
						let suffixWrapper = suffix.isEmpty ? "" : openingMarker +
							symmetric.marker + suffix + symmetric.marker + closingMarker
						return .init(
							range: NSRange(
								location: opening.location,
								length: closing.upperBound - opening.location),
							replacement: prefixWrapper + leadingWhitespace + selectedWrapper +
								trailingWhitespace + suffixWrapper,
							selection: NSRange(
								location: opening.location + (prefixWrapper as NSString).length +
									(leadingWhitespace as NSString).length + residualLength +
									(symmetric.marker as NSString).length,
								length: selection.length))
					}

					var prefixEnd = selection.location
					while prefixEnd > opening.upperBound {
						let character = text.character(at: prefixEnd - 1)
						guard character == 0x20 || character == 0x09 else { break }
						prefixEnd -= 1
					}
					var suffixStart = selection.upperBound
					while suffixStart < closing.location {
						let character = text.character(at: suffixStart)
						guard character == 0x20 || character == 0x09 else { break }
						suffixStart += 1
					}
					let prefix = text.substring(with: NSRange(
						location: opening.upperBound,
						length: prefixEnd - opening.upperBound))
					let leadingWhitespace = text.substring(with: NSRange(
						location: prefixEnd,
						length: selection.location - prefixEnd))
					let trailingWhitespace = text.substring(with: NSRange(
						location: selection.upperBound,
						length: suffixStart - selection.upperBound))
					let suffix = text.substring(with: NSRange(
						location: suffixStart,
						length: closing.location - suffixStart))
					guard !prefix.isEmpty || !suffix.isEmpty else { continue }

					let openingMarker = text.substring(with: opening)
					let closingMarker = text.substring(with: closing)
					let prefixWrapper = prefix.isEmpty ? "" :
						openingMarker + prefix + closingMarker
					let suffixWrapper = suffix.isEmpty ? "" :
						openingMarker + suffix + closingMarker
					let selectedWrapper = residual + selected + residual
					let replacement = prefixWrapper + leadingWhitespace + selectedWrapper +
						trailingWhitespace + suffixWrapper
					return .init(
						range: NSRange(
							location: opening.location,
							length: closing.upperBound - opening.location),
						replacement: replacement,
						selection: NSRange(
							location: opening.location + (prefixWrapper as NSString).length +
								(leadingWhitespace as NSString).length + residualLength,
							length: selection.length))
				}
			}
		}

		// When the style being removed is the outer member of a nested pair,
		// the inner markers must be closed on each untouched fragment and kept
		// around the selected text. Splitting only the outer marker strands the
		// inner opener and closer on different fragments.
		if selection.length > 0 {
			let innerCandidates = [
				(opening: "~~", closing: "~~"),
				(opening: "==", closing: "=="),
				(opening: "**", closing: "**"),
				(opening: "__", closing: "__"),
				(opening: "_", closing: "_"),
				(opening: "*", closing: "*"),
				(opening: "^", closing: "^"),
				(opening: "~", closing: "~"),
				(opening: "<u>", closing: "</u>"),
			]
			for candidate in [marker] + alternates {
				let length = (candidate as NSString).length
				var lineStart = selection.location
				while lineStart > 0 {
					let character = text.character(at: lineStart - 1)
					if character == 0x0A || character == 0x0D { break }
					lineStart -= 1
				}
				var opening = NSRange(location: NSNotFound, length: 0)
				var occurrenceCount = 0
				var scan = lineStart
				while scan + length <= selection.location {
					let occurrence = text.range(
						of: candidate,
						options: [],
						range: NSRange(
							location: scan,
							length: selection.location - scan))
					if occurrence.location == NSNotFound { break }
					opening = occurrence
					occurrenceCount += 1
					scan = occurrence.upperBound
				}
				guard occurrenceCount % 2 == 1 else { continue }

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

				if opening.upperBound < selection.location,
				   text.character(at: opening.upperBound) == 0x60 {
					var openingRunEnd = opening.upperBound
					while openingRunEnd < selection.location,
					      text.character(at: openingRunEnd) == 0x60 {
						openingRunEnd += 1
					}
					let codeMarkerLength = openingRunEnd - opening.upperBound
					var scan = openingRunEnd
					var codeClosing: NSRange?
					while scan < closing.location {
						guard text.character(at: scan) == 0x60 else {
							scan += 1
							continue
						}
						let runStart = scan
						while scan < closing.location,
						      text.character(at: scan) == 0x60 { scan += 1 }
						if scan - runStart == codeMarkerLength {
							codeClosing = NSRange(
								location: runStart, length: codeMarkerLength)
							break
						}
					}
					if let codeClosing, codeClosing.upperBound == closing.location {
						var contentStart = openingRunEnd
						var contentEnd = codeClosing.location
						if contentEnd - contentStart >= 2,
						   text.character(at: contentStart) == 0x20,
						   text.character(at: contentEnd - 1) == 0x20 {
							let raw = text.substring(with: NSRange(
								location: contentStart,
								length: contentEnd - contentStart))
							if raw.contains(where: { $0 != " " }) {
								contentStart += 1
								contentEnd -= 1
							}
						}
						if selection.location >= contentStart,
						   selection.upperBound <= contentEnd {
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
								location: contentStart,
								length: prefixEnd - contentStart))
							let leadingWhitespace = text.substring(with: NSRange(
								location: prefixEnd,
								length: selection.location - prefixEnd))
							let trailingWhitespace = text.substring(with: NSRange(
								location: selection.upperBound,
								length: suffixStart - selection.upperBound))
							let suffix = text.substring(with: NSRange(
								location: suffixStart,
								length: contentEnd - suffixStart))
							if prefix.isEmpty, suffix.isEmpty {
								return removingOuterWrapper(
									in: text, opening: opening, closing: closing,
									selection: selection)
							}
							if let selectedCode = MarkdownInlineCodeToggle.change(
								in: selected,
								selection: NSRange(
									location: 0, length: (selected as NSString).length)) {
								let prefixCode = prefix.isEmpty ? "" :
									MarkdownInlineCodeToggle.change(
										in: prefix,
										selection: NSRange(
											location: 0,
											length: (prefix as NSString).length))?.replacement ?? ""
								let suffixCode = suffix.isEmpty ? "" :
									MarkdownInlineCodeToggle.change(
										in: suffix,
										selection: NSRange(
											location: 0,
											length: (suffix as NSString).length))?.replacement ?? ""
								let prefixWrapper = prefix.isEmpty ? "" :
									candidate + prefixCode + candidate
								let suffixWrapper = suffix.isEmpty ? "" :
									candidate + suffixCode + candidate
								let replacement = prefixWrapper + leadingWhitespace +
									selectedCode.replacement + trailingWhitespace + suffixWrapper
								return .init(
									range: NSRange(
										location: opening.location,
										length: closing.upperBound - opening.location),
									replacement: replacement,
									selection: NSRange(
										location: opening.location +
											(prefixWrapper as NSString).length +
											(leadingWhitespace as NSString).length +
											selectedCode.selection.location,
										length: selection.length))
							}
						}
					}
				}

				// A link can be the inner style, but its closing marker includes a
				// dynamic destination. Match both balanced label brackets and nested
				// destination parentheses, then duplicate the exact destination on
				// every fragment that remains linked.
				if opening.upperBound < selection.location,
				   text.character(at: opening.upperBound) == 0x5B {
					var labelDepth = 0
					var escaped = false
					var labelClose: Int?
					var offset = opening.upperBound
					while offset < closing.location {
						let character = text.character(at: offset)
						if escaped {
							escaped = false
						} else if character == 0x5C {
							escaped = true
						} else if character == 0x5B {
							labelDepth += 1
						} else if character == 0x5D {
							labelDepth -= 1
							if labelDepth == 0 {
								labelClose = offset
								break
							}
						}
						offset += 1
					}
					if let labelClose,
					   labelClose + 2 <= closing.location,
					   text.substring(with: NSRange(
						location: labelClose, length: 2)) == "](",
					   selection.location > opening.upperBound,
					   selection.upperBound <= labelClose {
						var destinationClose = labelClose + 2
						var destinationDepth = 0
						escaped = false
						while destinationClose < closing.location {
							let character = text.character(at: destinationClose)
							if escaped {
								escaped = false
							} else if character == 0x5C {
								escaped = true
							} else if character == 0x28 {
								destinationDepth += 1
							} else if character == 0x29, destinationDepth > 0 {
								destinationDepth -= 1
							} else if character == 0x29 {
								break
							}
							destinationClose += 1
						}
						if destinationClose + 1 == closing.location {
							let contentStart = opening.upperBound + 1
							var prefixEnd = selection.location
							while prefixEnd > contentStart {
								let character = text.character(at: prefixEnd - 1)
								guard character == 0x20 || character == 0x09 else { break }
								prefixEnd -= 1
							}
							var suffixStart = selection.upperBound
							while suffixStart < labelClose {
								let character = text.character(at: suffixStart)
								guard character == 0x20 || character == 0x09 else { break }
								suffixStart += 1
							}
							let prefix = text.substring(with: NSRange(
								location: contentStart,
								length: prefixEnd - contentStart))
							let leadingWhitespace = text.substring(with: NSRange(
								location: prefixEnd,
								length: selection.location - prefixEnd))
							let trailingWhitespace = text.substring(with: NSRange(
								location: selection.upperBound,
								length: suffixStart - selection.upperBound))
							let suffix = text.substring(with: NSRange(
								location: suffixStart,
								length: labelClose - suffixStart))
							if prefix.isEmpty, suffix.isEmpty {
								return removingOuterWrapper(
									in: text, opening: opening, closing: closing,
									selection: selection)
							} else {
								let destination = text.substring(with: NSRange(
									location: labelClose,
									length: destinationClose + 1 - labelClose))
								let prefixWrapper = prefix.isEmpty ? "" :
									candidate + "[" + prefix + destination + candidate
								let selectedWrapper = "[" + selected + destination
								let suffixWrapper = suffix.isEmpty ? "" :
									candidate + "[" + suffix + destination + candidate
								let replacement = prefixWrapper + leadingWhitespace +
									selectedWrapper + trailingWhitespace + suffixWrapper
								return .init(
									range: NSRange(
										location: opening.location,
										length: closing.upperBound - opening.location),
									replacement: replacement,
									selection: NSRange(
										location: opening.location +
											(prefixWrapper as NSString).length +
											(leadingWhitespace as NSString).length + 1,
										length: selection.length))
							}
						}
					}
				}

				for inner in innerCandidates where
					inner.opening != candidate || inner.closing != candidate {
					let innerOpeningLength = (inner.opening as NSString).length
					let innerClosingLength = (inner.closing as NSString).length
					guard opening.upperBound + innerOpeningLength <= selection.location,
					      closing.location >= selection.upperBound + innerClosingLength,
					      text.substring(with: NSRange(
						location: opening.upperBound,
						length: innerOpeningLength)) == inner.opening,
					      text.substring(with: NSRange(
						location: closing.location - innerClosingLength,
						length: innerClosingLength)) == inner.closing else { continue }

					let contentStart = opening.upperBound + innerOpeningLength
					let contentEnd = closing.location - innerClosingLength
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
						location: prefixEnd,
						length: selection.location - prefixEnd))
					let trailingWhitespace = text.substring(with: NSRange(
						location: selection.upperBound,
						length: suffixStart - selection.upperBound))
					let suffix = text.substring(with: NSRange(
						location: suffixStart, length: contentEnd - suffixStart))
					if prefix.isEmpty, suffix.isEmpty {
						return removingOuterWrapper(
							in: text, opening: opening, closing: closing,
							selection: selection)
					}

					let prefixWrapper = prefix.isEmpty ? "" :
						candidate + inner.opening + prefix + inner.closing + candidate
					let selectedWrapper = inner.opening + selected + inner.closing
					let suffixWrapper = suffix.isEmpty ? "" :
						candidate + inner.opening + suffix + inner.closing + candidate
					let replacement = prefixWrapper + leadingWhitespace + selectedWrapper +
						trailingWhitespace + suffixWrapper
					return .init(
						range: NSRange(
							location: opening.location,
							length: closing.upperBound - opening.location),
						replacement: replacement,
						selection: NSRange(
							location: opening.location + (prefixWrapper as NSString).length +
								(leadingWhitespace as NSString).length + innerOpeningLength,
							length: selection.length))
				}
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

				if !markerBefore, !markerAfter {
					var lineStart = selection.location
					while lineStart > 0 {
						let character = text.character(at: lineStart - 1)
						if character == 0x0A || character == 0x0D { break }
						lineStart -= 1
					}
					var opening = NSRange(location: NSNotFound, length: 0)
					var occurrenceCount = 0
					var scan = lineStart
					while scan + length <= selection.location {
						let occurrence = text.range(
							of: candidate,
							options: [],
							range: NSRange(
								location: scan,
								length: selection.location - scan))
						if occurrence.location == NSNotFound { break }
						opening = occurrence
						occurrenceCount += 1
						scan = occurrence.upperBound
					}
					guard occurrenceCount % 2 == 1 else { continue }

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

					var prefixEnd = selection.location
					while prefixEnd > opening.upperBound {
						let character = text.character(at: prefixEnd - 1)
						guard character == 0x20 || character == 0x09 else { break }
						prefixEnd -= 1
					}
					var suffixStart = selection.upperBound
					while suffixStart < closing.location {
						let character = text.character(at: suffixStart)
						guard character == 0x20 || character == 0x09 else { break }
						suffixStart += 1
					}
					guard prefixEnd > opening.upperBound,
					      suffixStart < closing.location else { continue }

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
						length: closing.location - suffixStart))
					let replacement = prefix + candidate + leadingWhitespace +
						selected + trailingWhitespace + candidate + suffix + candidate
					return .init(
						range: NSRange(
							location: opening.location,
							length: closing.upperBound - opening.location),
						replacement: replacement,
						selection: NSRange(
							location: opening.location + (prefix as NSString).length +
								length + (leadingWhitespace as NSString).length,
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

		func labelDelimitersMatch(opening: Int, closing: Int) -> Bool {
			guard opening >= 0, closing < text.length,
			      text.character(at: opening) == 0x5B,
			      text.character(at: closing) == 0x5D else { return false }
			var depth = 0
			var escaped = false
			var offset = opening
			while offset <= closing {
				let character = text.character(at: offset)
				if escaped {
					escaped = false
				} else if character == 0x5C {
					escaped = true
				} else if character == 0x5B {
					depth += 1
				} else if character == 0x5D {
					depth -= 1
					if depth == 0 { return offset == closing }
					if depth < 0 { return false }
				}
				offset += 1
			}
			return false
		}

		func labelOpening(closing: Int, lineStart: Int) -> Int? {
			guard lineStart >= 0, closing < text.length else { return nil }
			var stack: [Int] = []
			var escaped = false
			var offset = lineStart
			while offset <= closing {
				let character = text.character(at: offset)
				if escaped {
					escaped = false
				} else if character == 0x5C {
					escaped = true
				} else if character == 0x5B {
					stack.append(offset)
				} else if character == 0x5D {
					guard let opening = stack.popLast() else { return nil }
					if offset == closing { return opening }
				}
				offset += 1
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
			let labelClose = text.range(
				of: "](",
				options: [],
				range: NSRange(
					location: selection.upperBound,
					length: lineEnd - selection.upperBound))
			if labelClose.location != NSNotFound,
			   let openingLocation = labelOpening(
				closing: labelClose.location, lineStart: lineStart),
			   let close = destinationClose(labelEnd: labelClose.location) {
				let opening = NSRange(location: openingLocation, length: 1)
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
			if let openingLocation = labelOpening(
				closing: selection.upperBound, lineStart: lineStart) {
				let opening = NSRange(location: openingLocation, length: 1)
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

			if !openingBefore, !closingAfter {
				var lineStart = selection.location
				while lineStart > 0 {
					let character = text.character(at: lineStart - 1)
					if character == 0x0A || character == 0x0D { break }
					lineStart -= 1
				}
				var openingStack: [NSRange] = []
				var scan = lineStart
				while scan < selection.location {
					let range = NSRange(
						location: scan, length: selection.location - scan)
					let nextOpening = text.range(
						of: opening, options: .caseInsensitive, range: range)
					let nextClosing = text.range(
						of: closing, options: .caseInsensitive, range: range)
					if nextOpening.location != NSNotFound,
					   (nextClosing.location == NSNotFound ||
						nextOpening.location < nextClosing.location) {
						openingStack.append(nextOpening)
						scan = nextOpening.upperBound
					} else if nextClosing.location != NSNotFound {
						if !openingStack.isEmpty { openingStack.removeLast() }
						scan = nextClosing.upperBound
					} else {
						break
					}
				}
				if let openingRange = openingStack.last {
					var lineEnd = selection.upperBound
					while lineEnd < text.length {
						let character = text.character(at: lineEnd)
						if character == 0x0A || character == 0x0D { break }
						lineEnd += 1
					}
					var closingRange: NSRange?
					var nestedDepth = 0
					scan = selection.upperBound
					while scan < lineEnd {
						let range = NSRange(location: scan, length: lineEnd - scan)
						let nextOpening = text.range(
							of: opening, options: .caseInsensitive, range: range)
						let nextClosing = text.range(
							of: closing, options: .caseInsensitive, range: range)
						if nextOpening.location != NSNotFound,
						   (nextClosing.location == NSNotFound ||
							nextOpening.location < nextClosing.location) {
							nestedDepth += 1
							scan = nextOpening.upperBound
						} else if nextClosing.location != NSNotFound {
							if nestedDepth == 0 {
								closingRange = nextClosing
								break
							}
							nestedDepth -= 1
							scan = nextClosing.upperBound
						} else {
							break
						}
					}
					if let closingRange {
						let openingMarker = text.substring(with: openingRange)
						let closingMarker = text.substring(with: closingRange)
						if openingRange.upperBound < selection.location,
						   text.character(at: openingRange.upperBound) == 0x60 {
							var openingRunEnd = openingRange.upperBound
							while openingRunEnd < selection.location,
							      text.character(at: openingRunEnd) == 0x60 {
								openingRunEnd += 1
							}
							let codeMarkerLength = openingRunEnd - openingRange.upperBound
							var scan = openingRunEnd
							var codeClosing: NSRange?
							while scan < closingRange.location {
								guard text.character(at: scan) == 0x60 else {
									scan += 1
									continue
								}
								let runStart = scan
								while scan < closingRange.location,
								      text.character(at: scan) == 0x60 { scan += 1 }
								if scan - runStart == codeMarkerLength {
									codeClosing = NSRange(
										location: runStart, length: codeMarkerLength)
									break
								}
							}
							if let codeClosing, codeClosing.upperBound == closingRange.location {
								var contentStart = openingRunEnd
								var contentEnd = codeClosing.location
								if contentEnd - contentStart >= 2,
								   text.character(at: contentStart) == 0x20,
								   text.character(at: contentEnd - 1) == 0x20 {
									let raw = text.substring(with: NSRange(
										location: contentStart,
										length: contentEnd - contentStart))
									if raw.contains(where: { $0 != " " }) {
										contentStart += 1
										contentEnd -= 1
									}
								}
								if selection.location >= contentStart,
								   selection.upperBound <= contentEnd {
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
										location: contentStart,
										length: prefixEnd - contentStart))
									let leadingWhitespace = text.substring(with: NSRange(
										location: prefixEnd,
										length: selection.location - prefixEnd))
									let trailingWhitespace = text.substring(with: NSRange(
										location: selection.upperBound,
										length: suffixStart - selection.upperBound))
									let suffix = text.substring(with: NSRange(
										location: suffixStart,
										length: contentEnd - suffixStart))
									if prefix.isEmpty, suffix.isEmpty {
										return removingOuterWrapper(
											in: text, opening: openingRange, closing: closingRange,
											selection: selection)
									}
									if let selectedCode = MarkdownInlineCodeToggle.change(
										in: selected,
										selection: NSRange(
											location: 0,
											length: (selected as NSString).length)) {
										let prefixCode = prefix.isEmpty ? "" :
											MarkdownInlineCodeToggle.change(
												in: prefix,
												selection: NSRange(
													location: 0,
													length: (prefix as NSString).length))?.replacement ?? ""
										let suffixCode = suffix.isEmpty ? "" :
											MarkdownInlineCodeToggle.change(
												in: suffix,
												selection: NSRange(
													location: 0,
													length: (suffix as NSString).length))?.replacement ?? ""
										let prefixWrapper = prefix.isEmpty ? "" :
											openingMarker + prefixCode + closingMarker
										let suffixWrapper = suffix.isEmpty ? "" :
											openingMarker + suffixCode + closingMarker
										let replacement = prefixWrapper + leadingWhitespace +
											selectedCode.replacement + trailingWhitespace + suffixWrapper
										return .init(
											range: NSRange(
												location: openingRange.location,
												length: closingRange.upperBound - openingRange.location),
											replacement: replacement,
											selection: NSRange(
												location: openingRange.location +
													(prefixWrapper as NSString).length +
													(leadingWhitespace as NSString).length +
													selectedCode.selection.location,
												length: selection.length))
									}
								}
							}
						}
						if openingRange.upperBound < selection.location,
						   text.character(at: openingRange.upperBound) == 0x5B {
							var labelDepth = 0
							var escaped = false
							var labelClose: Int?
							var offset = openingRange.upperBound
							while offset < closingRange.location {
								let character = text.character(at: offset)
								if escaped {
									escaped = false
								} else if character == 0x5C {
									escaped = true
								} else if character == 0x5B {
									labelDepth += 1
								} else if character == 0x5D {
									labelDepth -= 1
									if labelDepth == 0 {
										labelClose = offset
										break
									}
								}
								offset += 1
							}
							if let labelClose,
							   labelClose + 2 <= closingRange.location,
							   text.substring(with: NSRange(
								location: labelClose, length: 2)) == "](",
							   selection.location > openingRange.upperBound,
							   selection.upperBound <= labelClose {
								var destinationClose = labelClose + 2
								var destinationDepth = 0
								escaped = false
								while destinationClose < closingRange.location {
									let character = text.character(at: destinationClose)
									if escaped {
										escaped = false
									} else if character == 0x5C {
										escaped = true
									} else if character == 0x28 {
										destinationDepth += 1
									} else if character == 0x29, destinationDepth > 0 {
										destinationDepth -= 1
									} else if character == 0x29 {
										break
									}
									destinationClose += 1
								}
								if destinationClose + 1 == closingRange.location {
									let contentStart = openingRange.upperBound + 1
									var prefixEnd = selection.location
									while prefixEnd > contentStart {
										let character = text.character(at: prefixEnd - 1)
										guard character == 0x20 || character == 0x09 else { break }
										prefixEnd -= 1
									}
									var suffixStart = selection.upperBound
									while suffixStart < labelClose {
										let character = text.character(at: suffixStart)
										guard character == 0x20 || character == 0x09 else { break }
										suffixStart += 1
									}
									let prefix = text.substring(with: NSRange(
										location: contentStart,
										length: prefixEnd - contentStart))
									let leadingWhitespace = text.substring(with: NSRange(
										location: prefixEnd,
										length: selection.location - prefixEnd))
									let trailingWhitespace = text.substring(with: NSRange(
										location: selection.upperBound,
										length: suffixStart - selection.upperBound))
									let suffix = text.substring(with: NSRange(
										location: suffixStart,
										length: labelClose - suffixStart))
									if prefix.isEmpty, suffix.isEmpty {
										return removingOuterWrapper(
											in: text, opening: openingRange, closing: closingRange,
											selection: selection)
									} else {
										let destination = text.substring(with: NSRange(
											location: labelClose,
											length: destinationClose + 1 - labelClose))
										let prefixWrapper = prefix.isEmpty ? "" :
											openingMarker + "[" + prefix + destination + closingMarker
										let selectedWrapper = "[" + selected + destination
										let suffixWrapper = suffix.isEmpty ? "" :
											openingMarker + "[" + suffix + destination + closingMarker
										let replacement = prefixWrapper + leadingWhitespace +
											selectedWrapper + trailingWhitespace + suffixWrapper
										return .init(
											range: NSRange(
												location: openingRange.location,
												length: closingRange.upperBound - openingRange.location),
											replacement: replacement,
											selection: NSRange(
												location: openingRange.location +
													(prefixWrapper as NSString).length +
													(leadingWhitespace as NSString).length + 1,
												length: selection.length))
									}
								}
							}
						}
						let innerCandidates = ["~~", "==", "**", "__", "_", "*", "^", "~"]
						for inner in innerCandidates {
							let innerLength = (inner as NSString).length
							guard openingRange.upperBound + innerLength <= selection.location,
							      closingRange.location >= selection.upperBound + innerLength,
							      text.substring(with: NSRange(
								location: openingRange.upperBound,
								length: innerLength)) == inner,
							      text.substring(with: NSRange(
								location: closingRange.location - innerLength,
								length: innerLength)) == inner else { continue }

							let contentStart = openingRange.upperBound + innerLength
							let contentEnd = closingRange.location - innerLength
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
								location: contentStart,
								length: prefixEnd - contentStart))
							let leadingWhitespace = text.substring(with: NSRange(
								location: prefixEnd,
								length: selection.location - prefixEnd))
							let trailingWhitespace = text.substring(with: NSRange(
								location: selection.upperBound,
								length: suffixStart - selection.upperBound))
							let suffix = text.substring(with: NSRange(
								location: suffixStart,
								length: contentEnd - suffixStart))
							if prefix.isEmpty, suffix.isEmpty {
								return removingOuterWrapper(
									in: text, opening: openingRange, closing: closingRange,
									selection: selection)
							}

							let prefixWrapper = prefix.isEmpty ? "" :
								openingMarker + inner + prefix + inner + closingMarker
							let selectedWrapper = inner + selected + inner
							let suffixWrapper = suffix.isEmpty ? "" :
								openingMarker + inner + suffix + inner + closingMarker
							let replacement = prefixWrapper + leadingWhitespace +
								selectedWrapper + trailingWhitespace + suffixWrapper
							return .init(
								range: NSRange(
									location: openingRange.location,
									length: closingRange.upperBound - openingRange.location),
								replacement: replacement,
								selection: NSRange(
									location: openingRange.location +
										(prefixWrapper as NSString).length +
										(leadingWhitespace as NSString).length + innerLength,
									length: selection.length))
						}

						var prefixEnd = selection.location
						while prefixEnd > openingRange.upperBound {
							let character = text.character(at: prefixEnd - 1)
							guard character == 0x20 || character == 0x09 else { break }
							prefixEnd -= 1
						}
						var suffixStart = selection.upperBound
						while suffixStart < closingRange.location {
							let character = text.character(at: suffixStart)
							guard character == 0x20 || character == 0x09 else { break }
							suffixStart += 1
						}
						if prefixEnd > openingRange.upperBound,
						   suffixStart < closingRange.location {
							let prefix = text.substring(with: NSRange(
								location: openingRange.location,
								length: prefixEnd - openingRange.location))
							let leadingWhitespace = text.substring(with: NSRange(
								location: prefixEnd,
								length: selection.location - prefixEnd))
							let trailingWhitespace = text.substring(with: NSRange(
								location: selection.upperBound,
								length: suffixStart - selection.upperBound))
							let suffix = text.substring(with: NSRange(
								location: suffixStart,
								length: closingRange.location - suffixStart))
							let replacement = prefix + closingMarker + leadingWhitespace +
								selected + trailingWhitespace + openingMarker + suffix + closingMarker
							return .init(
								range: NSRange(
									location: openingRange.location,
									length: closingRange.upperBound - openingRange.location),
								replacement: replacement,
								selection: NSRange(
									location: openingRange.location + (prefix as NSString).length +
										(closingMarker as NSString).length +
										(leadingWhitespace as NSString).length,
									length: selection.length))
						}
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
