//
//  HTMLAttributeParser.swift
//  FeltTip
//

import Foundation
import SwiftUI

/// Shared HTML attribute extraction used by HTMLTableParser, HTMLInlineConverter, and BlockBuilder.
public enum HTMLAttributeParser {
	struct ImageInfo {
		let src: String
		let alt: String
		let width: CGFloat?
		let height: CGFloat?
	}

	struct LinkInfo {
		let href: String
		let inner: String
	}

	struct LinkedImageInfo {
		let href: String
		let src: String
		let alt: String
		let width: CGFloat?
		let height: CGFloat?
	}

	// MARK: - Extraction

	static func extractLinkedImage(from html: String) -> LinkedImageInfo? {
		let ns = html as NSString
		let range = NSRange(location: 0, length: ns.length)
		guard let match = Patterns.linkedImage.firstMatch(in: html, range: range) else { return nil }
		let href = ns.substring(with: match.range(at: 1))
		let src = ns.substring(with: match.range(at: 2))
		let alt = extractAttribute("alt", from: html) ?? ""
		let (w, h) = extractDimensions(from: html)
		return LinkedImageInfo(href: href, src: src, alt: alt, width: w, height: h)
	}

	static func extractImage(from html: String) -> ImageInfo? {
		let ns = html as NSString
		let range = NSRange(location: 0, length: ns.length)
		guard let match = Patterns.imgSrc.firstMatch(in: html, range: range) else { return nil }
		let src = ns.substring(with: match.range(at: 1))
		let alt = extractAttribute("alt", from: html) ?? ""
		let (w, h) = extractDimensions(from: html)
		return ImageInfo(src: src, alt: alt, width: w, height: h)
	}

	static func extractLink(from html: String) -> LinkInfo? {
		let ns = html as NSString
		guard let match = Patterns.anchor.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) else { return nil }
		return LinkInfo(href: ns.substring(with: match.range(at: 1)), inner: ns.substring(with: match.range(at: 2)))
	}

	static func extractAttribute(_ name: String, from html: String) -> String? {
		let ns = html as NSString
		let range = NSRange(location: 0, length: ns.length)
		guard let patterns = attributePatterns(for: name) else { return nil }
		if let match = patterns.quoted.firstMatch(in: html, range: range) {
			return ns.substring(with: match.range(at: 1))
		}
		// Unquoted: width=300
		if let match = patterns.unquoted.firstMatch(in: html, range: range) {
			return ns.substring(with: match.range(at: 1))
		}
		return nil
	}

	/// Attribute regexes compiled once per attribute name. This is called
	/// several times per `<img>` tag on every render; compiling per call made a
	/// badge-heavy README pay thousands of regex compiles per keystroke.
	private static let attributePatternLock = NSLock()
	nonisolated(unsafe) private static var attributePatternCache:
		[String: (quoted: NSRegularExpression, unquoted: NSRegularExpression)] = [:]

	private static func attributePatterns(
		for name: String
	) -> (quoted: NSRegularExpression, unquoted: NSRegularExpression)? {
		attributePatternLock.withLock {
			if let cached = attributePatternCache[name] { return cached }
			let escaped = NSRegularExpression.escapedPattern(for: name)
			guard let quoted = try? NSRegularExpression(
					pattern: "\(escaped)=[\"']([^\"']*)[\"']", options: .caseInsensitive),
			      let unquoted = try? NSRegularExpression(
					pattern: "\(escaped)=(\\S+)", options: .caseInsensitive) else { return nil }
			attributePatternCache[name] = (quoted, unquoted)
			return (quoted, unquoted)
		}
	}

	static func extractDimensions(from html: String) -> (width: CGFloat?, height: CGFloat?) {
		let ns = html as NSString
		let range = NSRange(location: 0, length: ns.length)
		let w = Patterns.width.firstMatch(in: html, range: range)
			.flatMap { Double(ns.substring(with: $0.range(at: 1))) }.map { CGFloat($0) }
		let h = Patterns.height.firstMatch(in: html, range: range)
			.flatMap { Double(ns.substring(with: $0.range(at: 1))) }.map { CGFloat($0) }
		return (w, h)
	}

	// MARK: - Text Helpers

	static func stripTags(_ html: String) -> String {
		html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
	}

	static func decodeEntities(_ text: String) -> String {
		var out = text
		for (key, value) in namedEntities {
			out = out.replacingOccurrences(of: key, with: value)
		}
		out = decodeNumericEntities(out)
		// Decode &amp; last so we don't double-decode something like &amp;nbsp;
		out = out.replacingOccurrences(of: "&amp;", with: "&")
		return out
	}

	private static let namedEntities: [(String, String)] = [
		("&nbsp;", "\u{00A0}"),
		("&lt;", "<"),
		("&gt;", ">"),
		("&quot;", "\""),
		("&apos;", "'"),
		("&#39;", "'"),
		("&copy;", "©"),
		("&reg;", "®"),
		("&trade;", "™"),
		("&mdash;", "—"),
		("&ndash;", "–"),
		("&hellip;", "…"),
		("&laquo;", "«"),
		("&raquo;", "»"),
		("&middot;", "·"),
		("&bull;", "•"),
		("&deg;", "°"),
		("&times;", "×"),
		("&divide;", "÷"),
		("&plusmn;", "±"),
		("&para;", "¶"),
		("&sect;", "§"),
		("&euro;", "€"),
		("&pound;", "£"),
		("&yen;", "¥"),
		("&cent;", "¢"),
	]

	private static let numericEntityPattern = try! NSRegularExpression(
		pattern: #"&#(x?)([0-9a-fA-F]+);"#, options: []
	)

	private static func decodeNumericEntities(_ text: String) -> String {
		let ns = text as NSString
		var result = ""
		var cursor = 0
		for match in numericEntityPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
			result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
			let isHex = !ns.substring(with: match.range(at: 1)).isEmpty
			let digits = ns.substring(with: match.range(at: 2))
			if let scalar = UInt32(digits, radix: isHex ? 16 : 10),
			   let unicode = Unicode.Scalar(scalar) {
				result.append(Character(unicode))
			} else {
				result += ns.substring(with: match.range)
			}
			cursor = match.range.location + match.range.length
		}
		if cursor < ns.length { result += ns.substring(from: cursor) }
		return result
	}

	static func collapseWhitespace(_ text: String) -> String {
		text.components(separatedBy: .whitespacesAndNewlines)
			.filter { !$0.isEmpty }
			.joined(separator: " ")
	}

	// MARK: - Compiled Patterns

	enum Patterns {
		static let imgSrc = try! NSRegularExpression(
			pattern: "<img[^>]*src=[\"']([^\"']+)[\"'][^>]*>", options: .caseInsensitive)
		static let anchor = try! NSRegularExpression(
			pattern: "<a[^>]*href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>",
			options: [.caseInsensitive, .dotMatchesLineSeparators])
		static let linkedImage = try! NSRegularExpression(
			pattern: "<a[^>]*href=[\"']([^\"']+)[\"'][^>]*>\\s*<img[^>]*src=[\"']([^\"']+)[\"'][^>]*>\\s*</a>",
			options: [.caseInsensitive, .dotMatchesLineSeparators])
		static let width = try! NSRegularExpression(
			pattern: #"\bwidth=["']?(\d+)"#, options: .caseInsensitive)
		static let height = try! NSRegularExpression(
			pattern: #"\bheight=["']?(\d+)"#, options: .caseInsensitive)
		static let pTag = try! NSRegularExpression(
			pattern: "<p([^>]*)>(.*?)</p>", options: [.caseInsensitive, .dotMatchesLineSeparators])
		static let align = try! NSRegularExpression(
			pattern: "align=[\"']([^\"']+)[\"']", options: .caseInsensitive)
	}
}
