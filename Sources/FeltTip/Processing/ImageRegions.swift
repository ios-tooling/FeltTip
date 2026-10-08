//
//  ImageRegions.swift
//  FeltTip
//
//  Locate every <img> tag in a chunk of HTML, in document order, and pair each
//  with its enclosing <a href="…"> if any. Used by HTMLInlineConverter to
//  interleave images with surrounding paragraph text.
//

import Foundation

enum ImageRegions {
	struct Hit {
		let range: NSRange
		let src: String
		let alt: String
		let link: String?
		let width: CGFloat?
		let height: CGFloat?
		let title: String?

		var rowItem: ImageRowItem {
			ImageRowItem(
				source: src,
				alt: alt,
				link: link.flatMap { URL(string: $0) },
				width: width,
				height: height,
				title: title
			)
		}

		func makeBlock(id: String) -> MarkdownBlock {
			if link != nil {
				return .imageRow(images: [rowItem], id: id)
			}
			return .image(source: src, alt: alt, width: width, height: height, id: id)
		}
	}

	static func collect(in html: String) -> [Hit] {
		let ns = html as NSString
		let fullRange = NSRange(location: 0, length: ns.length)
		var currentAnchor: String?
		var hits: [Hit] = []
		for match in tagPattern.matches(in: html, range: fullRange) {
			let fullTag = ns.substring(with: match.range)
			let lower = fullTag.lowercased()
			if lower.hasPrefix("</a") {
				currentAnchor = nil
				continue
			}
			if lower.hasPrefix("<a") {
				currentAnchor = HTMLAttributeParser.extractAttribute("href", from: fullTag)
				continue
			}
			guard let src = HTMLAttributeParser.extractAttribute("src", from: fullTag),
			      !src.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
			let alt = HTMLAttributeParser.extractAttribute("alt", from: fullTag) ?? ""
			let title = HTMLAttributeParser.extractAttribute("title", from: fullTag)
			let (w, h) = HTMLAttributeParser.extractDimensions(from: fullTag)
			hits.append(Hit(range: match.range, src: src, alt: alt, link: currentAnchor, width: w, height: h, title: title))
		}
		return hits
	}

	private static let tagPattern = try! NSRegularExpression(
		pattern: #"<(?:a\b[^>]*|/a\s*|img\b[^>]*)>"#, options: .caseInsensitive
	)
}
