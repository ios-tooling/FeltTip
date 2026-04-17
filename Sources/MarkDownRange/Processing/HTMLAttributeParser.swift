//
//  HTMLAttributeParser.swift
//  MarkDownRange
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

	// MARK: - Extraction

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
		let escaped = NSRegularExpression.escapedPattern(for: name)
		if let pattern = try? NSRegularExpression(pattern: "\(escaped)=[\"']([^\"']*)[\"']", options: .caseInsensitive),
		   let match = pattern.firstMatch(in: html, range: range) {
			return ns.substring(with: match.range(at: 1))
		}
		// Unquoted: width=300
		if let pattern = try? NSRegularExpression(pattern: "\(escaped)=(\\S+)", options: .caseInsensitive),
		   let match = pattern.firstMatch(in: html, range: range) {
			return ns.substring(with: match.range(at: 1))
		}
		return nil
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
		text.replacingOccurrences(of: "&amp;", with: "&")
			.replacingOccurrences(of: "&lt;", with: "<")
			.replacingOccurrences(of: "&gt;", with: ">")
			.replacingOccurrences(of: "&quot;", with: "\"")
			.replacingOccurrences(of: "&#39;", with: "'")
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
