//
//  HTMLInlineConverter.swift
//  FeltTip
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
		var segments: [(content: String, alignment: HorizontalAlignment?)] = []
		var cursor = 0
		for match in matches {
			if match.range.location > cursor {
				segments.append((ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), nil))
			}
			let attrs = ns.substring(with: match.range(at: 1))
			let content = ns.substring(with: match.range(at: 2))
			segments.append((content, parseAlignment(from: attrs)))
			cursor = NSMaxRange(match.range)
		}
		if cursor < ns.length { segments.append((ns.substring(from: cursor), nil)) }
		return segments
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
		// `isWhitespaceOnly` strips tags, so enclosing anchor markup does not
		// need a second pair of prefix/suffix regex scans.
		let spanStart = image.range.location
		let spanEnd = image.range.location + image.range.length
		let before = ns.substring(with: NSRange(location: 0, length: spanStart))
		let after = ns.substring(with: NSRange(location: spanEnd, length: ns.length - spanEnd))
		return isWhitespaceOnly(before) && isWhitespaceOnly(after)
	}

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
		let formatted = attributedHTML(html)
		guard !formatted.characters.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
		return [.paragraph(content: formatted, links: [], id: nextID())]
	}

	/// Walks an HTML fragment producing inline content that preserves
	/// inline emphasis tags: `<b>/<strong>` → bold, `<i>/<em>` → italic,
	/// `<code>/<kbd>` → monospaced, `<u>` → underline, `<s>/<del>/<strike>` →
	/// strikethrough. Unknown tags are stripped silently. Replaces the previous
	/// `stripTags`-only path so HTML-block segments inside `<p align="…">` and
	/// other non-anchor wrappers keep their formatting.
	static func attributedHTML(_ html: String) -> InlineContent {
		var result = InlineContent()
		var style: InlineStyle = []
		let ns = html as NSString
		var cursor = 0
		let matches = inlineTagRegex.matches(in: html, range: NSRange(location: 0, length: ns.length))

		func appendText(_ raw: String) {
			let decoded = HTMLAttributeParser.decodeEntities(raw)
			guard !decoded.isEmpty else { return }
			result.append(InlineRun(decoded, style: style))
		}

		for match in matches {
			if match.range.location > cursor {
				appendText(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
			}
			let closing = !ns.substring(with: match.range(at: 1)).isEmpty
			let name = ns.substring(with: match.range(at: 2)).lowercased()
			switch name {
			case "b", "strong":
				if closing { style.remove(.bold) } else { style.insert(.bold) }
			case "i", "em":
				if closing { style.remove(.italic) } else { style.insert(.italic) }
			case "code", "kbd":
				if closing { style.remove(.monospaced) } else { style.insert(.monospaced) }
			case "u":
				if closing { style.remove(.underline) } else { style.insert(.underline) }
			case "s", "del", "strike":
				if closing { style.remove(.strikethrough) } else { style.insert(.strikethrough) }
			default:
				break
			}
			cursor = match.range.location + match.range.length
		}
		if cursor < ns.length {
			appendText(ns.substring(from: cursor))
		}
		result.coalesce()
		return result
	}

	private static let inlineTagRegex = try! NSRegularExpression(
		pattern: #"<(/?)([a-zA-Z][a-zA-Z0-9]*)\b[^>]*>"#,
		options: []
	)

	static func buildParagraph(from html: String, preservingWhitespace: Bool = false) -> (text: InlineContent, links: [LinkInfo])? {
		let ns = html as NSString
		let matches = HTMLAttributeParser.Patterns.anchor.matches(in: html, range: NSRange(location: 0, length: ns.length))
		guard !matches.isEmpty else { return nil }

		var result = InlineContent()
		var links: [LinkInfo] = []
		var lastEnd = 0

		for (i, match) in matches.enumerated() {
			let beforeHTML = ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
			let beforeAttr = attributedHTML(preservingWhitespace ? beforeHTML : HTMLAttributeParser.collapseWhitespace(beforeHTML))
			if !beforeAttr.isEmpty {
				result += beforeAttr
				if !preservingWhitespace { result.append(InlineRun(" ")) }
			} else if i > 0 {
				if !preservingWhitespace { result.append(InlineRun(" ")) }
			}

			let href = HTMLAttributeParser.extractAttribute("href", from: ns.substring(with: match.range(at: 1)))
			let inner = ns.substring(with: match.range(at: 2))

			// Preserve italic/bold/etc. inside the link label; fall back to the
			// img alt-attribute or the literal "link" so we never emit an empty
			// anchor — matches the prior stripTags-based behavior.
			var labelAttr = attributedHTML(inner)
			if labelAttr.characters.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				let alt = HTMLAttributeParser.extractAttribute("alt", from: inner) ?? ""
				labelAttr = InlineContent(alt.isEmpty ? "link" : alt)
			}

			if let href, let url = URL(string: href) {
				let offset = result.characterCount
				labelAttr.setLink(url, fromRun: 0)
				result += labelAttr
				links.append(LinkInfo(url: href, characterOffset: offset))
			} else {
				result += labelAttr
			}

			lastEnd = match.range.location + match.range.length
		}

		if lastEnd < ns.length {
			let afterHTML = ns.substring(from: lastEnd)
			let afterAttr = attributedHTML(preservingWhitespace ? afterHTML : HTMLAttributeParser.collapseWhitespace(afterHTML))
			if !afterAttr.isEmpty {
				if !preservingWhitespace { result.append(InlineRun(" ")) }
				result += afterAttr
			}
		}

		result.coalesce()
		return result.isEmpty ? nil : (result, links)
	}
}
