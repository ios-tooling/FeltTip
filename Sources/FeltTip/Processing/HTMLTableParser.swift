//
//  HTMLTableParser.swift
//  FeltTip
//

import Foundation

enum HTMLTableParser {
	struct ParsedTable {
		let header: [TableCell]
		let rows: [[TableCell]]
		let columnAlignments: [TableColumnAlignment]
	}

	static func parse(html: String) -> ParsedTable? {
		guard html.lowercased().contains("<table") else { return nil }

		let rawRows = splitTag(html, tag: "tr")
		guard !rawRows.isEmpty else { return nil }

		var header: [TableCell] = []
		var rows: [[TableCell]] = []
		var alignments: [TableColumnAlignment] = []

		for (index, rawRow) in rawRows.enumerated() {
			let isHeader = index == 0 && rawRow.lowercased().contains("<th")
			let rawCells = splitTagWithOpening(rawRow, tag: isHeader ? "th" : "td")
			let cells = rawCells.map { cellContent(from: $0.body) }
			if isHeader {
				header = cells
				alignments = rawCells.map { alignment(fromOpeningTag: $0.opening) }
			} else {
				if alignments.isEmpty {
					alignments = Array(repeating: .default, count: cells.count)
				}
				rows.append(cells)
			}
		}

		guard !rows.isEmpty || !header.isEmpty else { return nil }
		return ParsedTable(header: header, rows: rows, columnAlignments: alignments)
	}

	private static func splitTag(_ html: String, tag: String) -> [String] {
		splitTagWithOpening(html, tag: tag).map(\.body)
	}

	/// One compiled pattern per tag name (`tr`, `th`, `td`); this runs once per
	/// table row, so compiling per call scaled with row count.
	private static let tagPatternLock = NSLock()
	nonisolated(unsafe) private static var tagPatternCache: [String: NSRegularExpression] = [:]

	private static func tagPattern(_ tag: String) -> NSRegularExpression {
		tagPatternLock.withLock {
			if let cached = tagPatternCache[tag] { return cached }
			let pattern = try! NSRegularExpression(
				pattern: "(<\(tag)[^>]*>)(.*?)</\(tag)>",
				options: [.caseInsensitive, .dotMatchesLineSeparators]
			)
			tagPatternCache[tag] = pattern
			return pattern
		}
	}

	private static func splitTagWithOpening(_ html: String, tag: String) -> [(opening: String, body: String)] {
		let pattern = tagPattern(tag)
		let ns = html as NSString
		return pattern.matches(in: html, range: NSRange(location: 0, length: ns.length)).map {
			(opening: ns.substring(with: $0.range(at: 1)), body: ns.substring(with: $0.range(at: 2)))
		}
	}

	private static func alignment(fromOpeningTag tag: String) -> TableColumnAlignment {
		guard let value = HTMLAttributeParser.extractAttribute("align", from: tag)?.lowercased() else { return .default }
		switch value {
		case "left":   return .left
		case "center": return .center
		case "right":  return .right
		default:       return .default
		}
	}

	private static func cellContent(from html: String) -> TableCell {
		let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.isEmpty { return .text(AttributedString()) }

		if let link = HTMLAttributeParser.extractLink(from: trimmed),
		   let img = HTMLAttributeParser.extractImage(from: link.inner) {
			return .image(source: img.src, alt: img.alt, link: URL(string: link.href), width: img.width, height: img.height)
		}

		if let img = HTMLAttributeParser.extractImage(from: trimmed) {
			return .image(source: img.src, alt: img.alt, link: nil, width: img.width, height: img.height)
		}

		if let link = HTMLAttributeParser.extractLink(from: trimmed) {
			let text = HTMLAttributeParser.stripTags(link.inner).trimmingCharacters(in: .whitespacesAndNewlines)
			var str = AttributedString(text.isEmpty ? link.href : text)
			if let url = URL(string: link.href) { str.link = url }
			return .text(str)
		}

		return .text(AttributedString(HTMLAttributeParser.decodeEntities(HTMLAttributeParser.stripTags(trimmed))))
	}
}
