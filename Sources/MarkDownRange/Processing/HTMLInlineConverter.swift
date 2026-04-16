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
		guard lower.contains("<a ") || lower.contains("<img") || lower.contains("<p") else { return nil }

		var blocks: [MarkdownBlock] = []
		var counter = 0
		func nextID() -> String { counter += 1; return "\(id)-\(counter)" }

		let segments = splitParagraphs(trimmed)
		for segment in segments {
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

	private static func splitParagraphs(_ html: String) -> [(content: String, alignment: HorizontalAlignment?)] {
		let pattern = try! NSRegularExpression(
			pattern: "<p([^>]*)>(.*?)</p>",
			options: [.caseInsensitive, .dotMatchesLineSeparators]
		)
		let ns = html as NSString
		let matches = pattern.matches(in: html, range: NSRange(location: 0, length: ns.length))
		if matches.isEmpty { return [(html, nil)] }
		return matches.map { match in
			let attrs = ns.substring(with: match.range(at: 1))
			let content = ns.substring(with: match.range(at: 2))
			return (content, parseAlignment(from: attrs))
		}
	}

	private static func parseAlignment(from attrs: String) -> HorizontalAlignment? {
		let pattern = try! NSRegularExpression(pattern: "align=[\"']([^\"']+)[\"']", options: .caseInsensitive)
		let ns = attrs as NSString
		guard let match = pattern.firstMatch(in: attrs, range: NSRange(location: 0, length: ns.length)) else { return nil }
		switch ns.substring(with: match.range(at: 1)).lowercased() {
		case "center": return .center
		case "right": return .trailing
		default: return nil
		}
	}

	private static func convertSegment(_ html: String, nextID: () -> String) -> [MarkdownBlock] {
		let linkedImages = extractLinkedImages(from: html)
		let hasTextLinks = containsTextLinks(html, excluding: linkedImages)

		// Only linked images, no text → image row (or single image)
		if !linkedImages.isEmpty && !hasTextLinks {
			if linkedImages.count == 1 {
				let img = linkedImages[0]
				return [.image(source: img.src, alt: img.alt, width: img.width, height: img.height, id: nextID())]
			}
			let items = linkedImages.map { (source: $0.src, alt: $0.alt, link: URL(string: $0.href), width: $0.width, height: $0.height) }
			return [.imageRow(images: items, id: nextID())]
		}

		// Single standalone image with no links
		if let img = extractStandaloneImage(from: html) {
			return [.image(source: img.src, alt: img.alt, width: img.width, height: img.height, id: nextID())]
		}

		// Text with links
		if let paragraph = buildParagraph(from: html) {
			return [.paragraph(content: paragraph.text, links: paragraph.links, id: nextID())]
		}

		// Plain text fallback
		let plain = stripTags(html).trimmingCharacters(in: .whitespacesAndNewlines)
		if !plain.isEmpty {
			return [.paragraph(content: AttributedString(plain), links: [], id: nextID())]
		}

		return []
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

	private static func extractLinkedImages(from html: String) -> [(src: String, alt: String, href: String, width: CGFloat?, height: CGFloat?)] {
		let pattern = try! NSRegularExpression(
			pattern: "<a[^>]*href=[\"']([^\"']+)[\"'][^>]*>\\s*<img[^>]*src=[\"']([^\"']+)[\"'][^>]*>\\s*</a>",
			options: [.caseInsensitive, .dotMatchesLineSeparators]
		)
		let ns = html as NSString
		return pattern.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { match in
			let href = ns.substring(with: match.range(at: 1))
			let src = ns.substring(with: match.range(at: 2))
			let fullTag = ns.substring(with: match.range)
			let alt = extractAlt(from: fullTag) ?? ""
			let (w, h) = extractDimensions(from: fullTag)
			return (src, alt, href, w, h)
		}
	}

	private static func extractStandaloneImage(from html: String) -> (src: String, alt: String, width: CGFloat?, height: CGFloat?)? {
		let textContent = stripTags(html).trimmingCharacters(in: .whitespacesAndNewlines)
		guard textContent.isEmpty else { return nil }
		guard html.lowercased().contains("<img"), !html.lowercased().contains("<a ") else { return nil }
		let ns = html as NSString
		let srcPattern = try! NSRegularExpression(pattern: "<img[^>]*src=[\"']([^\"']+)[\"']", options: .caseInsensitive)
		guard let srcMatch = srcPattern.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) else { return nil }
		let src = ns.substring(with: srcMatch.range(at: 1))
		let alt = extractAlt(from: html) ?? ""
		let (w, h) = extractDimensions(from: html)
		return (src, alt, w, h)
	}

	private static func buildParagraph(from html: String) -> (text: AttributedString, links: [LinkInfo])? {
		let linkPattern = try! NSRegularExpression(
			pattern: "<a[^>]*href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>",
			options: [.caseInsensitive, .dotMatchesLineSeparators]
		)
		let ns = html as NSString
		let matches = linkPattern.matches(in: html, range: NSRange(location: 0, length: ns.length))
		guard !matches.isEmpty else { return nil }

		var result = AttributedString()
		var links: [LinkInfo] = []
		var lastEnd = 0

		for (i, match) in matches.enumerated() {
			let before = ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
			let plainBefore = collapseWhitespace(stripTags(before))
			if !plainBefore.isEmpty {
				result += AttributedString(plainBefore + " ")
			} else if i > 0 {
				result += AttributedString(" ")
			}

			let href = ns.substring(with: match.range(at: 1))
			let inner = ns.substring(with: match.range(at: 2))

			// Use stripped text, or fall back to img alt text
			var linkText = stripTags(inner).trimmingCharacters(in: .whitespacesAndNewlines)
			if linkText.isEmpty { linkText = extractAlt(from: inner) ?? "" }
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
			let plain = collapseWhitespace(stripTags(after))
			if !plain.isEmpty { result += AttributedString(" " + plain) }
		}

		return result.characters.isEmpty ? nil : (result, links)
	}

	private static func extractDimensions(from html: String) -> (width: CGFloat?, height: CGFloat?) {
		let ns = html as NSString
		let range = NSRange(location: 0, length: ns.length)
		let wPattern = try! NSRegularExpression(pattern: #"\bwidth=["']?(\d+)"#, options: .caseInsensitive)
		let hPattern = try! NSRegularExpression(pattern: #"\bheight=["']?(\d+)"#, options: .caseInsensitive)
		let w = wPattern.firstMatch(in: html, range: range).flatMap { Double(ns.substring(with: $0.range(at: 1))) }.map { CGFloat($0) }
		let h = hPattern.firstMatch(in: html, range: range).flatMap { Double(ns.substring(with: $0.range(at: 1))) }.map { CGFloat($0) }
		return (w, h)
	}

	private static func extractAlt(from html: String) -> String? {
		let pattern = try! NSRegularExpression(pattern: "alt=[\"']([^\"']*)[\"']", options: .caseInsensitive)
		let ns = html as NSString
		return pattern.firstMatch(in: html, range: NSRange(location: 0, length: ns.length))
			.map { ns.substring(with: $0.range(at: 1)) }
	}

	private static func collapseWhitespace(_ text: String) -> String {
		text.components(separatedBy: .whitespacesAndNewlines)
			.filter { !$0.isEmpty }
			.joined(separator: " ")
	}

	private static func stripTags(_ html: String) -> String {
		html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
	}
}
