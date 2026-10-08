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
		guard let link = extractLink(from: html), let image = extractImage(from: link.inner) else { return nil }
		return LinkedImageInfo(href: link.href, src: image.src, alt: image.alt, width: image.width, height: image.height)
	}

	static func extractImage(from html: String) -> ImageInfo? {
		let ns = html as NSString
		guard let match = Patterns.imgSrc.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) else { return nil }
		let tag = ns.substring(with: match.range)
		guard let src = extractAttribute("src", from: tag),
		      !src.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
		let (width, height) = extractDimensions(from: tag)
		return ImageInfo(src: src, alt: extractAttribute("alt", from: tag) ?? "", width: width, height: height)
	}

	static func extractLink(from html: String) -> LinkInfo? {
		let ns = html as NSString
		guard let match = Patterns.anchor.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
		      let href = extractAttribute("href", from: ns.substring(with: match.range(at: 1))) else { return nil }
		return LinkInfo(href: href, inner: ns.substring(with: match.range(at: 2)))
	}

	/// Scan complete attributes, consuming quoted values as a unit so names
	/// embedded in data attributes or other values cannot become real attributes.
	/// A name may follow whitespace or, as browsers allow, a previous quoted value.
	static func extractAttribute(_ name: String, from html: String) -> String? {
		let ns = html as NSString
		for match in attributePattern.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
			guard ns.substring(with: match.range(at: 1)).lowercased() == name.lowercased() else { continue }
			for group in 2...4 where match.range(at: group).location != NSNotFound {
				return decodeEntities(ns.substring(with: match.range(at: group)))
			}
		}
		return nil
	}

	private static let attributePattern = try! NSRegularExpression(
		pattern: #"(?<=[\s"'])([^\s=/>"']+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>\x60]+))"#
	)

	static func extractDimensions(from html: String) -> (width: CGFloat?, height: CGFloat?) {
		func dimension(_ name: String) -> CGFloat? {
			guard let value = extractAttribute(name, from: html),
			      let number = Double(value.prefix { $0.isNumber }) else { return nil }
			return CGFloat(number)
		}
		return (dimension("width"), dimension("height"))
	}

	// MARK: - Text Helpers

	static func stripTags(_ html: String) -> String {
		html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
	}

	static func decodeEntities(_ text: String) -> String {
		// Decode only tokens in the original input. A decoded ampersand must
		// not cause a second entity to be interpreted (e.g. &#38;amp;).
		let ns = text as NSString
		var result = ""
		var cursor = 0
		for match in entityPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
			result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
			let token = ns.substring(with: match.range)
			if token.hasPrefix("&#") {
				let digits = token.dropFirst(2).dropLast()
				let hex = digits.first == "x" || digits.first == "X"
				if let value = UInt32(String(hex ? digits.dropFirst() : digits), radix: hex ? 16 : 10),
				   let scalar = Unicode.Scalar(value) {
					result.unicodeScalars.append(scalar)
				} else { result += token }
			} else {
				result += token == "&amp;" ? "&" : (namedEntities.first { $0.0 == token }?.1 ?? token)
			}
			cursor = NSMaxRange(match.range)
		}
		result += ns.substring(from: cursor)
		return result
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

	private static let entityPattern = try! NSRegularExpression(
		pattern: #"&(?:#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z][a-zA-Z0-9]*);"#
	)

	static func collapseWhitespace(_ text: String) -> String {
		text.components(separatedBy: .whitespacesAndNewlines)
			.filter { !$0.isEmpty }
			.joined(separator: " ")
	}

	// MARK: - Compiled Patterns

	enum Patterns {

		static let imgSrc = try! NSRegularExpression(
			pattern: #"<img\b(?:[^>"']|"[^"]*"|'[^']*')*>"#, options: .caseInsensitive)
		// Group 1 is the whole opening tag; callers use exact attribute extraction.
		static let anchor = try! NSRegularExpression(
			pattern: #"(<a\b(?:[^>"']|"[^"]*"|'[^']*')*>)(.*?)</a\s*>"#,
			options: [.caseInsensitive, .dotMatchesLineSeparators])
		static let pTag = try! NSRegularExpression(
			pattern: "<p([^>]*)>(.*?)</p>", options: [.caseInsensitive, .dotMatchesLineSeparators])
		static let align = try! NSRegularExpression(
			pattern: "align=[\"']([^\"']+)[\"']", options: .caseInsensitive)
	}
}
