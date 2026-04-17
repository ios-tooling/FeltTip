//
//  HTMLTableParser.swift
//  MarkDownRange
//

import Foundation

enum HTMLTableParser {
	struct ParsedTable {
		let header: [TableCell]
		let rows: [[TableCell]]
	}

	static func parse(html: String) -> ParsedTable? {
		guard html.lowercased().contains("<table") else { return nil }

		let rawRows = splitTag(html, tag: "tr")
		guard !rawRows.isEmpty else { return nil }

		var header: [TableCell] = []
		var rows: [[TableCell]] = []

		for (index, rawRow) in rawRows.enumerated() {
			let isHeader = index == 0 && rawRow.lowercased().contains("<th")
			let cells = splitTag(rawRow, tag: isHeader ? "th" : "td").map { cellContent(from: $0) }
			if isHeader { header = cells } else { rows.append(cells) }
		}

		guard !rows.isEmpty || !header.isEmpty else { return nil }
		return ParsedTable(header: header, rows: rows)
	}

	private static func splitTag(_ html: String, tag: String) -> [String] {
		let pattern = try! NSRegularExpression(
			pattern: "<\(tag)[^>]*>(.*?)</\(tag)>",
			options: [.caseInsensitive, .dotMatchesLineSeparators]
		)
		let ns = html as NSString
		return pattern.matches(in: html, range: NSRange(location: 0, length: ns.length)).map {
			ns.substring(with: $0.range(at: 1))
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
