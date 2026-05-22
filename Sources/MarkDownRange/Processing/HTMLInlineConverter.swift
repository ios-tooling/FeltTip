//
//  HTMLInlineConverter.swift
//  MarkDownRange
//

import Foundation
import SwiftUI

enum HTMLInlineConverter {
	static func convert(html: String, id: String) -> [MarkdownBlock]? {
		let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
		let lower = trimmed.lowercased()
		guard lower.contains("<a ") || lower.contains("<img") || lower.contains("<p>") || lower.contains("<p ") else { return nil }

		var blocks: [MarkdownBlock] = []
		var counter = 0
		func nextID() -> String { counter += 1; return "\(id)-\(counter)" }

		for segment in splitParagraphs(flattenContainers(trimmed)) {
			let seg = segment.content.trimmingCharacters(in: .whitespacesAndNewlines)
			if seg.isEmpty { continue }
			let segBlocks = convertSegment(seg, nextID: nextID)
			if let alignment = segment.alignment {
				blocks.append(contentsOf: segBlocks.map { .aligned(alignment: alignment, block: $0, id: nextID()) })
			} else {
				blocks.append(contentsOf: segBlocks)
			}
		}

		return blocks.isEmpty ? nil : blocks
	}

	// MARK: - Container flattening

	/// Strips `<div>`, `<picture>`, and `<source>` opening/closing tags so their
	/// inner content is processed by the rest of the pipeline. Alignment hints on
	/// `<div align="...">` are promoted to a wrapping `<p align="...">` so paragraph
	/// splitting picks them up.
	private static func flattenContainers(_ html: String) -> String {
		var out = html
		out = out.replacingOccurrences(
			of: #"<div([^>]*\balign=["'](?:center|right|left)["'][^>]*)>"#,
			with: "<p$1>", options: [.regularExpression, .caseInsensitive])
		out = out.replacingOccurrences(of: #"</div\s*>"#, with: "</p>",
									   options: [.regularExpression, .caseInsensitive])
		out = out.replacingOccurrences(of: #"<div\b[^>]*>"#, with: "",
									   options: [.regularExpression, .caseInsensitive])
		out = out.replacingOccurrences(of: #"</?(picture|source)\b[^>]*>"#, with: "",
									   options: [.regularExpression, .caseInsensitive])
		return out
	}

	// MARK: - Paragraph splitting

	private static func splitParagraphs(_ html: String) -> [(content: String, alignment: HorizontalAlignment?)] {
		let ns = html as NSString
		let matches = HTMLAttributeParser.Patterns.pTag.matches(in: html, range: NSRange(location: 0, length: ns.length))
		if matches.isEmpty { return [(html, nil)] }
		return matches.map { match in
			let attrs = ns.substring(with: match.range(at: 1))
			let content = ns.substring(with: match.range(at: 2))
			return (content, parseAlignment(from: attrs))
		}
	}

	private static func parseAlignment(from attrs: String) -> HorizontalAlignment? {
		let ns = attrs as NSString
		guard let match = HTMLAttributeParser.Patterns.align.firstMatch(in: attrs, range: NSRange(location: 0, length: ns.length)) else { return nil }
		switch ns.substring(with: match.range(at: 1)).lowercased() {
		case "center": return .center
		case "right": return .trailing
		default: return nil
		}
	}

	// MARK: - Segment conversion

	private static func convertSegment(_ html: String, nextID: () -> String) -> [MarkdownBlock] {
		let images = ImageRegions.collect(in: html)

		if images.isEmpty {
			return makeTextBlocks(html, nextID: nextID)
		}

		// Mirror BlockBuilder's promotion rule for HTML blocks too: when the
		// segment contains exactly one image, no surrounding non-whitespace
		// text, and the image carries a `title` attribute, emit a `.figure`
		// so HTML-form images get the same captioned-figure treatment as the
		// markdown `![alt](url "caption")` syntax.
		if images.count == 1, segmentIsImageOnly(html, image: images[0]) {
			let only = images[0]
			if let title = only.title, !title.isEmpty {
				return [.figure(image: only.rowItem, caption: title, id: nextID())]
			}
			return [only.makeBlock(id: nextID())]
		}

		var blocks: [MarkdownBlock] = []
		let ns = html as NSString
		var cursor = 0
		var pending: [ImageRegions.Hit] = []

		func flush() {
			guard !pending.isEmpty else { return }
			if pending.count == 1 {
				blocks.append(pending[0].makeBlock(id: nextID()))
			} else {
				let items = pending.map { $0.rowItem }
				blocks.append(.imageRow(images: items, id: nextID()))
			}
			pending.removeAll()
		}

		for image in images {
			if image.range.location > cursor {
				let between = ns.substring(with: NSRange(location: cursor, length: image.range.location - cursor))
				// `<br>` between images used to split the row into separate
				// `.imageRow` blocks, but that put each row in its own
				// MarkdownContentView VStack child with a 14pt spacing the
				// inner FlowLayout couldn't influence. The flow layout now
				// handles wrapping natively, so leave all images in one row
				// and let it wrap based on width — the inter-row gap then
				// follows `FlowLayout.verticalSpacing`.
				if !isWhitespaceOnly(between) {
					flush()
					blocks.append(contentsOf: makeTextBlocks(between, nextID: nextID))
				}
			}
			pending.append(image)
			cursor = image.range.location + image.range.length
		}
		flush()

		if cursor < ns.length {
			blocks.append(contentsOf: makeTextBlocks(ns.substring(from: cursor), nextID: nextID))
		}
		return blocks
	}

	private static func segmentIsImageOnly(_ html: String, image: ImageRegions.Hit) -> Bool {
		let ns = html as NSString
		// Include an enclosing `<a href="…">…</a>` (when present) in the
		// "image span," since BlockBuilder's HTML-image extractor and the
		// regions collector both treat the anchor as part of the image.
		var spanStart = image.range.location
		var spanEnd = image.range.location + image.range.length
		if image.link != nil {
			if let openMatch = openAnchorPattern.matches(in: html, range: NSRange(location: 0, length: spanStart)).last {
				spanStart = openMatch.range.location
			}
			if let closeMatch = closeAnchorPattern.firstMatch(in: html, range: NSRange(location: spanEnd, length: ns.length - spanEnd)) {
				spanEnd = closeMatch.range.location + closeMatch.range.length
			}
		}
		let before = ns.substring(with: NSRange(location: 0, length: spanStart))
		let after = ns.substring(with: NSRange(location: spanEnd, length: ns.length - spanEnd))
		return isWhitespaceOnly(before) && isWhitespaceOnly(after)
	}

	private static let openAnchorPattern = try! NSRegularExpression(
		pattern: #"<a[^>]*href=["'][^"']+["'][^>]*>"#, options: .caseInsensitive
	)

	private static let closeAnchorPattern = try! NSRegularExpression(
		pattern: #"</a\s*>"#, options: .caseInsensitive
	)

	private static func isWhitespaceOnly(_ html: String) -> Bool {
		HTMLAttributeParser.decodeEntities(HTMLAttributeParser.stripTags(html))
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.isEmpty
	}

	// MARK: - Text segments

	private static func makeTextBlocks(_ html: String, nextID: () -> String) -> [MarkdownBlock] {
		if let paragraph = buildParagraph(from: html) {
			return [.paragraph(content: paragraph.text, links: paragraph.links, id: nextID())]
		}
		let plain = HTMLAttributeParser.decodeEntities(HTMLAttributeParser.stripTags(html))
			.trimmingCharacters(in: .whitespacesAndNewlines)
		if !plain.isEmpty {
			return [.paragraph(content: AttributedString(plain), links: [], id: nextID())]
		}
		return []
	}

	private static func buildParagraph(from html: String) -> (text: AttributedString, links: [LinkInfo])? {
		let ns = html as NSString
		let matches = HTMLAttributeParser.Patterns.anchor.matches(in: html, range: NSRange(location: 0, length: ns.length))
		guard !matches.isEmpty else { return nil }

		var result = AttributedString()
		var links: [LinkInfo] = []
		var lastEnd = 0

		for (i, match) in matches.enumerated() {
			let before = ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
			let plainBefore = HTMLAttributeParser.decodeEntities(HTMLAttributeParser.collapseWhitespace(HTMLAttributeParser.stripTags(before)))
			if !plainBefore.isEmpty {
				result += AttributedString(plainBefore + " ")
			} else if i > 0 {
				result += AttributedString(" ")
			}

			let href = ns.substring(with: match.range(at: 1))
			let inner = ns.substring(with: match.range(at: 2))

			var linkText = HTMLAttributeParser.decodeEntities(HTMLAttributeParser.stripTags(inner)).trimmingCharacters(in: .whitespacesAndNewlines)
			if linkText.isEmpty { linkText = HTMLAttributeParser.extractAttribute("alt", from: inner) ?? "" }
			if linkText.isEmpty { linkText = "link" }

			if let url = URL(string: href) {
				let offset = result.characters.count
				var linkStr = AttributedString(linkText)
				linkStr.link = url
				result += linkStr
				links.append(LinkInfo(url: href, characterOffset: offset))
			}

			lastEnd = match.range.location + match.range.length
		}

		if lastEnd < ns.length {
			let after = ns.substring(from: lastEnd)
			let plain = HTMLAttributeParser.decodeEntities(HTMLAttributeParser.collapseWhitespace(HTMLAttributeParser.stripTags(after)))
			if !plain.isEmpty { result += AttributedString(" " + plain) }
		}

		return result.characters.isEmpty ? nil : (result, links)
	}
}
