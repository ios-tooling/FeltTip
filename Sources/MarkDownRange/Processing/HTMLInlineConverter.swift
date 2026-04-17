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

		for segment in splitParagraphs(trimmed) {
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

	// MARK: - Paragraph Splitting

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

	// MARK: - Segment Conversion

	private static func convertSegment(_ html: String, nextID: () -> String) -> [MarkdownBlock] {
		let linkedImages = extractLinkedImages(from: html)
		let hasTextLinks = containsTextLinks(html, excluding: linkedImages)

		if !linkedImages.isEmpty && !hasTextLinks {
			if linkedImages.count == 1 {
				let img = linkedImages[0]
				return [.image(source: img.src, alt: img.alt, width: img.width, height: img.height, id: nextID())]
			}
			return [.imageRow(images: linkedImages.map {
				ImageRowItem(source: $0.src, alt: $0.alt, link: URL(string: $0.href), width: $0.width, height: $0.height)
			}, id: nextID())]
		}

		if let img = extractStandaloneImage(from: html) {
			return [.image(source: img.src, alt: img.alt, width: img.width, height: img.height, id: nextID())]
		}

		if let paragraph = buildParagraph(from: html) {
			return [.paragraph(content: paragraph.text, links: paragraph.links, id: nextID())]
		}

		let plain = HTMLAttributeParser.stripTags(html).trimmingCharacters(in: .whitespacesAndNewlines)
		if !plain.isEmpty {
			return [.paragraph(content: AttributedString(plain), links: [], id: nextID())]
		}

		return []
	}

	// MARK: - Image Extraction

	private static func extractLinkedImages(from html: String) -> [(src: String, alt: String, href: String, width: CGFloat?, height: CGFloat?)] {
		let ns = html as NSString
		return HTMLAttributeParser.Patterns.linkedImage.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { match in
			let fullTag = ns.substring(with: match.range)
			let href = ns.substring(with: match.range(at: 1))
			let src = ns.substring(with: match.range(at: 2))
			let alt = HTMLAttributeParser.extractAttribute("alt", from: fullTag) ?? ""
			let (w, h) = HTMLAttributeParser.extractDimensions(from: fullTag)
			return (src, alt, href, w, h)
		}
	}

	private static func extractStandaloneImage(from html: String) -> HTMLAttributeParser.ImageInfo? {
		let textContent = HTMLAttributeParser.stripTags(html).trimmingCharacters(in: .whitespacesAndNewlines)
		guard textContent.isEmpty, html.lowercased().contains("<img"), !html.lowercased().contains("<a ") else { return nil }
		return HTMLAttributeParser.extractImage(from: html)
	}

	private static func containsTextLinks(_ html: String, excluding linkedImages: [(src: String, alt: String, href: String, width: CGFloat?, height: CGFloat?)]) -> Bool {
		var stripped = html
		for img in linkedImages {
			if let range = stripped.range(of: "<a[^>]*href=[\"']\(NSRegularExpression.escapedPattern(for: img.href))[\"'][^>]*>\\s*<img[^>]*>\\s*</a>", options: .regularExpression) {
				stripped.removeSubrange(range)
			}
		}
		return stripped.lowercased().contains("<a ")
	}

	// MARK: - Paragraph Building

	private static func buildParagraph(from html: String) -> (text: AttributedString, links: [LinkInfo])? {
		let ns = html as NSString
		let matches = HTMLAttributeParser.Patterns.anchor.matches(in: html, range: NSRange(location: 0, length: ns.length))
		guard !matches.isEmpty else { return nil }

		var result = AttributedString()
		var links: [LinkInfo] = []
		var lastEnd = 0

		for (i, match) in matches.enumerated() {
			let before = ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
			let plainBefore = HTMLAttributeParser.collapseWhitespace(HTMLAttributeParser.stripTags(before))
			if !plainBefore.isEmpty {
				result += AttributedString(plainBefore + " ")
			} else if i > 0 {
				result += AttributedString(" ")
			}

			let href = ns.substring(with: match.range(at: 1))
			let inner = ns.substring(with: match.range(at: 2))

			var linkText = HTMLAttributeParser.stripTags(inner).trimmingCharacters(in: .whitespacesAndNewlines)
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
			let plain = HTMLAttributeParser.collapseWhitespace(HTMLAttributeParser.stripTags(after))
			if !plain.isEmpty { result += AttributedString(" " + plain) }
		}

		return result.characters.isEmpty ? nil : (result, links)
	}
}
