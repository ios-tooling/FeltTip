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
		let lower = html.lowercased()
		guard lower.contains("<table") else { return nil }

		let rawRows = splitTag(html, tag: "tr")
		guard !rawRows.isEmpty else { return nil }

		var header: [TableCell] = []
		var rows: [[TableCell]] = []

		for (index, rawRow) in rawRows.enumerated() {
			let isHeader = index == 0 && rawRow.lowercased().contains("<th")
			let cells = splitTag(rawRow, tag: isHeader ? "th" : "td")
			let tableCells = cells.map { cellContent(from: $0) }

			if isHeader {
				header = tableCells
			} else {
				rows.append(tableCells)
			}
		}

		guard !rows.isEmpty || !header.isEmpty else { return nil }
		return ParsedTable(header: header, rows: rows)
	}

	private static func splitTag(_ html: String, tag: String) -> [String] {
		let pattern = try! NSRegularExpression(
			pattern: "<\(tag)[^>]*>(.*?)</\(tag)>",
			options: [.caseInsensitive, .dotMatchesLineSeparators]
		)
		let nsHTML = html as NSString
		return pattern.matches(in: html, range: NSRange(location: 0, length: nsHTML.length)).map {
			nsHTML.substring(with: $0.range(at: 1))
		}
	}

	private static func cellContent(from html: String) -> TableCell {
		let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.isEmpty { return .text(AttributedString()) }

		// Linked image: <a href="..."><img src="..." alt="..."></a>
		if let link = extractLink(from: trimmed), let img = extractImage(from: link.inner) {
			return .image(source: img.src, alt: img.alt, link: URL(string: link.href), width: img.width, height: img.height)
		}

		// Standalone image
		if let img = extractImage(from: trimmed) {
			return .image(source: img.src, alt: img.alt, link: nil, width: img.width, height: img.height)
		}

		// Link with text
		if let link = extractLink(from: trimmed) {
			let text = stripTags(link.inner).trimmingCharacters(in: .whitespacesAndNewlines)
			var str = AttributedString(text.isEmpty ? link.href : text)
			if let url = URL(string: link.href) { str.link = url }
			return .text(str)
		}

		// Plain text
		return .text(AttributedString(decodeEntities(stripTags(trimmed))))
	}

	private static func extractLink(from html: String) -> (href: String, inner: String)? {
		let pattern = try! NSRegularExpression(
			pattern: "<a[^>]*href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>",
			options: [.caseInsensitive, .dotMatchesLineSeparators]
		)
		let ns = html as NSString
		guard let match = pattern.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) else { return nil }
		return (ns.substring(with: match.range(at: 1)), ns.substring(with: match.range(at: 2)))
	}

	private static func extractImage(from html: String) -> (src: String, alt: String, width: CGFloat?, height: CGFloat?)? {
		let pattern = try! NSRegularExpression(
			pattern: "<img[^>]*src=[\"']([^\"']+)[\"'][^>]*>",
			options: .caseInsensitive
		)
		let ns = html as NSString
		let range = NSRange(location: 0, length: ns.length)
		guard let match = pattern.firstMatch(in: html, range: range) else { return nil }
		let src = ns.substring(with: match.range(at: 1))
		let altPattern = try! NSRegularExpression(pattern: "alt=[\"']([^\"']*)[\"']", options: .caseInsensitive)
		let alt = altPattern.firstMatch(in: html, range: range)
			.map { ns.substring(with: $0.range(at: 1)) } ?? ""
		let wPattern = try! NSRegularExpression(pattern: #"\bwidth=["']?(\d+)"#, options: .caseInsensitive)
		let hPattern = try! NSRegularExpression(pattern: #"\bheight=["']?(\d+)"#, options: .caseInsensitive)
		let w = wPattern.firstMatch(in: html, range: range).flatMap { Double(ns.substring(with: $0.range(at: 1))) }.map { CGFloat($0) }
		let h = hPattern.firstMatch(in: html, range: range).flatMap { Double(ns.substring(with: $0.range(at: 1))) }.map { CGFloat($0) }
		return (src, alt, w, h)
	}

	private static func stripTags(_ html: String) -> String {
		html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
	}

	private static func decodeEntities(_ text: String) -> String {
		text.replacingOccurrences(of: "&amp;", with: "&")
			.replacingOccurrences(of: "&lt;", with: "<")
			.replacingOccurrences(of: "&gt;", with: ">")
			.replacingOccurrences(of: "&quot;", with: "\"")
			.replacingOccurrences(of: "&#39;", with: "'")
	}
}
