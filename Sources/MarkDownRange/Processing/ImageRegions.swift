//
//  ImageRegions.swift
//  MarkDownRange
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

		func makeBlock(id: String) -> MarkdownBlock {
			if let href = link, let url = URL(string: href) {
				let item = ImageRowItem(source: src, alt: alt, link: url, width: width, height: height)
				return .imageRow(images: [item], id: id)
			}
			return .image(source: src, alt: alt, width: width, height: height, id: id)
		}
	}

	static func collect(in html: String) -> [Hit] {
		let ns = html as NSString
		let fullRange = NSRange(location: 0, length: ns.length)

		return imgPattern.matches(in: html, range: fullRange).map { match in
			let fullTag = ns.substring(with: match.range)
			let src = ns.substring(with: match.range(at: 1))
			let alt = HTMLAttributeParser.extractAttribute("alt", from: fullTag) ?? ""
			let (w, h) = HTMLAttributeParser.extractDimensions(from: fullTag)
			let link = enclosingAnchorHref(in: html, ns: ns, before: match.range.location)
			return Hit(range: match.range, src: src, alt: alt, link: link, width: w, height: h)
		}
	}

	private static let imgPattern = try! NSRegularExpression(
		pattern: #"<img[^>]*src=["']([^"']+)["'][^>]*>"#, options: .caseInsensitive
	)

	private static let openAnchorPattern = try! NSRegularExpression(
		pattern: #"<a[^>]*href=["']([^"']+)["'][^>]*>"#, options: .caseInsensitive
	)

	private static let closeAnchorPattern = try! NSRegularExpression(
		pattern: #"</a\s*>"#, options: .caseInsensitive
	)

	/// Last `<a href="…">` opening before `position` with no `</a>` between it and `position`.
	private static func enclosingAnchorHref(in html: String, ns: NSString, before position: Int) -> String? {
		let prefixRange = NSRange(location: 0, length: position)
		let opens = openAnchorPattern.matches(in: html, range: prefixRange)
		guard let lastOpen = opens.last else { return nil }
		let afterOpenStart = lastOpen.range.location + lastOpen.range.length
		let between = NSRange(location: afterOpenStart, length: position - afterOpenStart)
		if closeAnchorPattern.firstMatch(in: html, range: between) != nil { return nil }
		return ns.substring(with: lastOpen.range(at: 1))
	}
}
