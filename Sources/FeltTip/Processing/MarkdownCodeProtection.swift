import Foundation

/// Keep the parser's code regions opaque to the extension preprocessors.
/// A single shared boundary handles long/tilde fences, nested and indented
/// blocks, HTML blocks, and multi-backtick or multiline inline spans
/// consistently, with one line scan rather than a second cmark parse per
/// render.
enum MarkdownCodeProtection {
	@TaskLocal private static var isProtecting = false
	@TaskLocal private static var blockMarkerPrefix: String?
	@TaskLocal private static var inlineMarkerPrefix: String?

	static func containsProtectedBlock(_ line: String) -> Bool {
		guard let blockMarkerPrefix else { return false }
		return line.contains(blockMarkerPrefix)
	}

	/// The end of a masked inline code span starting at `index`, when one
	/// does. Processors that pair markers across plain text treat the token
	/// as the opaque code span it stands for, so `~a `x` b~` never pairs
	/// across the span.
	static func protectedInlineToken(in line: String, at index: String.Index) -> String.Index? {
		guard let inlineMarkerPrefix, line[index...].hasPrefix(inlineMarkerPrefix),
		      let end = line.range(of: "END", range: index..<line.endIndex) else { return nil }
		return end.upperBound
	}

	private struct Region {
		let range: NSRange
		let isBlock: Bool
	}
	static func ranges(in source: String, blocksOnly: Bool = false) -> [NSRange] {
		regions(in: source, blocksOnly: blocksOnly).map(\.range)
	}

	// MARK: - Scanner

	private static let space: UInt16 = 0x20, tab: UInt16 = 0x09, newline: UInt16 = 0x0A, carriageReturn: UInt16 = 0x0D
	private static let backtick: UInt16 = 0x60, tilde: UInt16 = 0x7E, backslash: UInt16 = 0x5C
	private static let quoteMarker: UInt16 = 0x3E, hash: UInt16 = 0x23, lessThan: UInt16 = 0x3C

	private enum HTMLBlockKind { case untilBlank, untilClosingTag([UInt16]), untilCommentEnd }

	/// Code regions in document order, following CommonMark's block and
	/// code-span rules: fences of three or more backticks or tildes that
	/// close on a run at least as long of the same character, indented code
	/// after a block boundary, container prefixes for quotes and list items,
	/// HTML blocks whose backticks are literal, and backtick spans that
	/// close on a run of exactly the opening length within one paragraph.
	private static func regions(in source: String, blocksOnly: Bool) -> [Region] {
		guard mayContainCode(source) else { return [] }
		let units = Array(source.utf16)
		let count = units.count
		var regions: [Region] = []

		struct Fence { let character: UInt16; let length: Int; let quoteDepth: Int; let start: Int; var lastLineEnd: Int }
		struct ListItem { let contentIndent: Int; let quoteDepth: Int }

		var fence: Fence?
		var indented: (start: Int, lastLineEnd: Int)?
		var html: HTMLBlockKind?
		var listItems: [ListItem] = []
		var previousLineBlank = true
		/// The previous non-blank line ended a block that is not a paragraph,
		/// so an indented line here starts code rather than continuing text.
		var atBlockBoundary = true
		var paragraph: (start: Int, end: Int, lines: Int)?
		var inTable = false

		func emit(_ range: NSRange) { regions.append(Region(range: range, isBlock: false)) }
		/// GFM splits a row into cells at unescaped pipes before inline
		/// parsing, so a span never crosses a cell.
		func scanRow(from start: Int, to end: Int) {
			guard !blocksOnly else { return }
			var cellStart = start
			var i = start
			while i < end {
				if units[i] == 0x7C, i == start || units[i - 1] != backslash {
					scanSpans(in: units, from: cellStart, to: i, emit)
					cellStart = i + 1
				}
				i += 1
			}
			scanSpans(in: units, from: cellStart, to: end, emit)
		}
		func closeParagraph() {
			guard let open = paragraph else { return }
			paragraph = nil
			guard !blocksOnly else { return }
			scanSpans(in: units, from: open.start, to: open.end, emit)
		}
		func extendParagraph(from start: Int, to end: Int) {
			if let open = paragraph { paragraph = (open.start, end, open.lines + 1) } else { paragraph = (start, end, 1) }
		}
		/// The content indent of the innermost list item at a quote depth.
		func base(for depth: Int) -> Int {
			listItems.last(where: { $0.quoteDepth == depth })?.contentIndent ?? 0
		}
		func isDelimiterRow(from start: Int, to end: Int) -> Bool {
			var cells = 0
			var dashes = 0
			for unit in units[start..<end] {
				switch unit {
				case 0x7C: if dashes > 0 { cells += 1 }; dashes = 0
				case 0x2D: dashes += 1
				case 0x3A, space, tab: break
				default: return false
				}
			}
			return cells + (dashes > 0 ? 1 : 0) >= 1 && units[start..<end].contains(0x2D)
		}
		func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }
		func contains(_ needle: [UInt16], in range: Range<Int>) -> Bool {
			guard needle.count <= range.count else { return false }
			var i = range.lowerBound
			while i + needle.count <= range.upperBound {
				var matched = true
				for (offset, unit) in needle.enumerated() where lowercased(units[i + offset]) != unit { matched = false; break }
				if matched { return true }
				i += 1
			}
			return false
		}
		let commentEnd = Array("-->".utf16)

		var lineStart = 0
		while lineStart <= count {
			var lineEnd = lineStart
			while lineEnd < count, units[lineEnd] != newline { lineEnd += 1 }
			var contentEnd = lineEnd
			while contentEnd > lineStart, units[contentEnd - 1] == carriageReturn || units[contentEnd - 1] == space || units[contentEnd - 1] == tab { contentEnd -= 1 }
			defer { lineStart = lineEnd + 1 }

			// Container prefix: indentation and quote markers.
			var position = lineStart
			var column = 0
			var quoteDepth = 0
			func skipIndent() {
				while position < contentEnd {
					if units[position] == space { column += 1 } else if units[position] == tab { column += 4 - column % 4 } else { break }
					position += 1
				}
			}
			while true {
				skipIndent()
				guard position < contentEnd, units[position] == quoteMarker, column - base(for: quoteDepth) <= 3 else { break }
				quoteDepth += 1
				position += 1
				column = 0
				if position < contentEnd, units[position] == space { position += 1 }
			}
			let isBlank = position >= contentEnd
			let indent = column

			if var open = fence {
				if quoteDepth < open.quoteDepth {
					// The quote holding the fence ended; the block ends with it.
					regions.append(Region(range: NSRange(location: open.start, length: open.lastLineEnd - open.start), isBlock: true))
					fence = nil
					atBlockBoundary = true
				} else {
					let relative = indent - base(for: quoteDepth)
					var run = position
					while run < contentEnd, units[run] == open.character { run += 1 }
					if relative <= 3, run - position >= open.length, run == contentEnd {
						regions.append(Region(range: NSRange(location: open.start, length: lineEnd - open.start), isBlock: true))
						fence = nil
						atBlockBoundary = true
						previousLineBlank = false
					} else {
						open.lastLineEnd = lineEnd
						fence = open
					}
					continue
				}
			}
			if let block = indented {
				if isBlank { previousLineBlank = true; continue }
				if indent - base(for: quoteDepth) >= 4 {
					indented = (block.start, lineEnd)
					previousLineBlank = false
					continue
				}
				regions.append(Region(range: NSRange(location: block.start, length: block.lastLineEnd - block.start), isBlock: true))
				indented = nil
				atBlockBoundary = true
			}
			if let open = html {
				switch open {
				case .untilBlank:
					if isBlank { html = nil } else { previousLineBlank = false; continue }
				case .untilClosingTag(let tag):
					if contains(tag, in: position..<contentEnd) { html = nil; atBlockBoundary = true }
					previousLineBlank = isBlank
					continue
				case .untilCommentEnd:
					if contains(commentEnd, in: position..<contentEnd) { html = nil; atBlockBoundary = true }
					previousLineBlank = isBlank
					continue
				}
			}
			if isBlank {
				closeParagraph()
				inTable = false
				previousLineBlank = true
				atBlockBoundary = true
				continue
			}

			// Which block constructs this line could start, after its prefix.
			let fenceRun: (character: UInt16, length: Int)? = {
				let character = units[position]
				guard character == backtick || character == tilde else { return nil }
				var run = position
				while run < contentEnd, units[run] == character { run += 1 }
				guard run - position >= 3 else { return nil }
				if character == backtick, units[run..<contentEnd].contains(backtick) { return nil }
				return (character, run - position)
			}()
			let listMarkerEnd: Int? = {
				let unit = units[position]
				var end = position + 1
				if unit == 0x2D || unit == 0x2B || unit == 0x2A {
				} else if isDigit(unit) {
					while end < contentEnd, isDigit(units[end]), end - position < 9 { end += 1 }
					guard end < contentEnd, units[end] == 0x2E || units[end] == 0x29 else { return nil }
					end += 1
				} else { return nil }
				guard end == contentEnd || units[end] == space || units[end] == tab else { return nil }
				return end
			}()
			let isHeading: Bool = {
				guard units[position] == hash else { return false }
				var run = position
				while run < contentEnd, units[run] == hash { run += 1 }
				return run - position <= 6 && (run == contentEnd || units[run] == space || units[run] == tab)
			}()
			let isThematicBreak: Bool = {
				let character = units[position]
				guard character == 0x2D || character == 0x2A || character == 0x5F else { return false }
				var marks = 0
				for unit in units[position..<contentEnd] {
					if unit == character { marks += 1 } else if unit != space, unit != tab { return false }
				}
				return marks >= 3
			}()
			let startsBlock = fenceRun != nil || listMarkerEnd != nil || isHeading || isThematicBreak

			// Leave list items this line is not indented into, or whose quote
			// has ended, unless it lazily continues the item's paragraph.
			var leftListItem = false
			while let item = listItems.last,
			      quoteDepth < item.quoteDepth || (quoteDepth == item.quoteDepth && indent < item.contentIndent) {
				guard previousLineBlank || startsBlock || html != nil else { break }
				listItems.removeLast()
				leftListItem = true
			}
			let relative = max(0, indent - base(for: quoteDepth))

			if inTable {
				if startsBlock { inTable = false } else {
					scanRow(from: position, to: contentEnd)
					previousLineBlank = false
					atBlockBoundary = false
					continue
				}
			}

			if relative <= 3, let fenceRun {
				closeParagraph()
				fence = Fence(character: fenceRun.character, length: fenceRun.length, quoteDepth: quoteDepth, start: position, lastLineEnd: lineEnd)
				previousLineBlank = false
				continue
			}
			if relative >= 4, atBlockBoundary {
				closeParagraph()
				indented = (position, lineEnd)
				previousLineBlank = false
				continue
			}
			if relative <= 3, let markerEnd = listMarkerEnd {
				closeParagraph()
				var spaces = 0
				var contentStart = markerEnd
				while contentStart < contentEnd, units[contentStart] == space || units[contentStart] == tab { spaces += 1; contentStart += 1 }
				let padding = spaces >= 1 && spaces <= 4 && contentStart < contentEnd ? spaces : 1
				listItems.append(ListItem(contentIndent: indent + (markerEnd - position) + padding, quoteDepth: quoteDepth))
				if contentStart < contentEnd { extendParagraph(from: contentStart, to: contentEnd) }
				previousLineBlank = false
				atBlockBoundary = contentStart >= contentEnd
				continue
			}
			if relative <= 3, isHeading {
				closeParagraph()
				extendParagraph(from: position, to: contentEnd)
				closeParagraph()
				previousLineBlank = false
				atBlockBoundary = true
				continue
			}
			// A setext underline turns the open paragraph into a heading; a
			// delimiter row turns a one-line paragraph into a table header.
			if relative <= 3, let open = paragraph, !leftListItem,
			   units[position] == 0x3D || units[position] == 0x2D,
			   units[position..<contentEnd].allSatisfy({ $0 == units[position] }) {
				closeParagraph()
				previousLineBlank = false
				atBlockBoundary = true
				continue
			} else if relative <= 3, let open = paragraph, open.lines == 1, !leftListItem,
			          isDelimiterRow(from: position, to: contentEnd) {
				paragraph = nil
				scanRow(from: open.start, to: open.end)
				inTable = true
				previousLineBlank = false
				atBlockBoundary = false
				continue
			}
			if relative <= 3, isThematicBreak {
				closeParagraph()
				previousLineBlank = false
				atBlockBoundary = true
				continue
			}
			if relative <= 3, units[position] == lessThan,
			   let block = htmlBlockStart(units, position: position, end: contentEnd, interruptingParagraph: paragraph != nil) {
				closeParagraph()
				html = block
				switch block {
				case .untilBlank: break
				case .untilClosingTag(let tag):
					if contains(tag, in: (position + 1)..<contentEnd) { html = nil }
				case .untilCommentEnd:
					if contains(commentEnd, in: (position + 4)..<contentEnd) { html = nil }
				}
				previousLineBlank = false
				atBlockBoundary = true
				continue
			}

			extendParagraph(from: position, to: contentEnd)
			previousLineBlank = false
			atBlockBoundary = false
		}

		if let open = fence {
			regions.append(Region(range: NSRange(location: open.start, length: open.lastLineEnd - open.start), isBlock: true))
		}
		if let block = indented {
			regions.append(Region(range: NSRange(location: block.start, length: block.lastLineEnd - block.start), isBlock: true))
		}
		closeParagraph()
		return regions
	}

	/// Backtick spans in one paragraph: an opening run closes on the next
	/// run of exactly its length; otherwise it is literal. Backslashes
	/// escape backticks outside spans only.
	private static func scanSpans(in units: [UInt16], from start: Int, to end: Int, _ emit: (NSRange) -> Void) {
		var i = start
		while i < end {
			let unit = units[i]
			if unit == backslash { i += 2; continue }
			guard unit == backtick else { i += 1; continue }
			var run = i
			while run < end, units[run] == backtick { run += 1 }
			let length = run - i
			var scan = run
			var closing: Int?
			while scan < end {
				guard units[scan] == backtick else { scan += 1; continue }
				let runStart = scan
				while scan < end, units[scan] == backtick { scan += 1 }
				if scan - runStart == length { closing = runStart; break }
			}
			if let closing {
				emit(NSRange(location: i, length: closing + length - i))
				i = closing + length
			} else {
				i = run
			}
		}
	}

	private static func lowercased(_ unit: UInt16) -> UInt16 { unit >= 0x41 && unit <= 0x5A ? unit + 0x20 : unit }

	private static let rawTextTags = ["pre", "script", "style", "textarea"].map { Array($0.utf16) }
	private static let blockTags: Set<String> = [
		"address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col",
		"colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure",
		"footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr",
		"html", "iframe", "legend", "li", "link", "main", "menu", "menuitem", "nav", "noframes", "ol",
		"optgroup", "option", "p", "param", "search", "section", "summary", "table", "tbody", "td", "tfoot",
		"th", "thead", "title", "tr", "track", "ul",
	]

	/// The HTML block kind a line starting with `<` opens, per CommonMark:
	/// raw-text elements and comments span blank lines; known block tags end
	/// at one; any other complete tag alone on its line does too, but only
	/// outside a paragraph.
	private static func htmlBlockStart(_ units: [UInt16], position: Int, end: Int, interruptingParagraph: Bool) -> HTMLBlockKind? {
		var cursor = position + 1
		if cursor + 2 < end, units[cursor] == 0x21, units[cursor + 1] == 0x2D, units[cursor + 2] == 0x2D { return .untilCommentEnd }
		if cursor < end, units[cursor] == 0x21 || units[cursor] == 0x3F { return .untilBlank }
		let closing = cursor < end && units[cursor] == 0x2F
		if closing { cursor += 1 }
		let nameStart = cursor
		while cursor < end, (lowercased(units[cursor]) >= 0x61 && lowercased(units[cursor]) <= 0x7A) || (units[cursor] >= 0x30 && units[cursor] <= 0x39) { cursor += 1 }
		guard cursor > nameStart else { return nil }
		let name = String(utf16CodeUnits: units[nameStart..<cursor].map(lowercased), count: cursor - nameStart)
		let terminated = cursor == end || units[cursor] == space || units[cursor] == tab || units[cursor] == 0x3E
			|| (units[cursor] == 0x2F && cursor + 1 < end && units[cursor + 1] == 0x3E)
		if !closing, terminated, let tag = rawTextTags.first(where: { String(utf16CodeUnits: $0, count: $0.count) == name }) {
			return .untilClosingTag(Array("</".utf16) + tag)
		}
		if blockTags.contains(name), terminated { return .untilBlank }
		// Any other tag counts only when it is complete and alone on the line.
		guard !interruptingParagraph, let close = units[cursor..<end].lastIndex(of: 0x3E) else { return nil }
		return units[(close + 1)..<end].allSatisfy({ $0 == space || $0 == tab }) ? .untilBlank : nil
	}

	/// A cheap rejection for documents that cannot contain code: no backtick,
	/// tab, or tilde fence, and no line starting with four spaces (indented
	/// code can follow any block boundary, so the line before is no guide).
	private static func mayContainCode(_ source: String) -> Bool {
		var source = source
		return source.withUTF8 { bytes in
			var spaces = 0
			var tildes = 0
			var lineStart = true
			for byte in bytes {
				if byte == 0x60 || byte == 0x09 { return true }
				if byte == 0x0A {
					lineStart = true
					spaces = 0
					tildes = 0
					continue
				}
				if lineStart, byte == 0x20 {
					spaces += 1
					if spaces == 4 { return true }
				} else {
					lineStart = false
				}
				tildes = byte == 0x7E ? tildes + 1 : 0
				if tildes == 3 { return true }
			}
			return false
		}
	}

	// MARK: - Masking

	static func transform(_ source: String, using transform: (String) -> String?) -> String? {
		map(source) { masked, restore in transform(masked).map(restore) }
	}

	static func map<T>(_ source: String, using transform: (String, (String) -> String) -> T) -> T {
		guard !isProtecting else { return transform(source, { $0 }) }
		let regions = regions(in: source, blocksOnly: false)
		guard !regions.isEmpty else { return $isProtecting.withValue(true) { transform(source, { $0 }) } }
		var prefix: String
		repeat { prefix = "FELTTIPCODE" + UUID().uuidString.replacingOccurrences(of: "-", with: "") } while source.contains(prefix)
		let ns = source as NSString
		var originals: [String] = []
		var masked = ""
		var cursor = 0
		// One token per line preserves block/container boundaries. Restoring
		// a token never introduces new lines into a transformed quote/list.
		func appendTokens(for text: String, isBlock: Bool) {
			for (index, line) in text.components(separatedBy: "\n").enumerated() {
				if index > 0 { masked += "\n" }
				if !line.isEmpty {
					masked += prefix + (isBlock ? "BLOCK" : "INLINE") + String(originals.count) + "END"
					originals.append(line)
				}
			}
		}
		for region in regions {
			let range = region.range
			masked += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
			appendTokens(for: ns.substring(with: range), isBlock: region.isBlock)
			cursor = NSMaxRange(range)
		}
		masked += ns.substring(from: cursor)
		func restore(_ processed: String) -> String {
			var restored = ""
			var start = processed.startIndex
			while let marker = processed.range(of: prefix, range: start..<processed.endIndex) {
				restored += processed[start..<marker.lowerBound]
				guard let end = processed.range(of: "END", range: marker.upperBound..<processed.endIndex),
				      let index = Int(processed[marker.upperBound..<end.lowerBound].dropFirst(processed[marker.upperBound...].hasPrefix("BLOCK") ? 5 : 6)),
				      originals.indices.contains(index) else {
					restored += prefix
					start = marker.upperBound
					continue
				}
				restored += originals[index]
				start = end.upperBound
			}
			restored += processed[start...]
			return restored
		}
		return $isProtecting.withValue(true) {
			$blockMarkerPrefix.withValue(prefix + "BLOCK") {
				$inlineMarkerPrefix.withValue(prefix + "INLINE") { transform(masked, restore) }
			}
		}
	}
}
