//
//  SVGDimensionParser.swift
//  MarkDownRange
//
//  Pulls intrinsic dimensions from an SVG document.
//

import Foundation
import CoreGraphics

enum SVGDimensionParser {
	/// Returns the SVG's intrinsic size by reading `width`/`height` attributes
	/// or the `viewBox`. Returns `nil` if neither is parseable.
	static func parse(_ svg: String) -> CGSize? {
		guard let svgTag = openSVGTag(in: svg) else { return nil }
		let explicit = explicitDimensions(in: svgTag)
		if let w = explicit.width, let h = explicit.height {
			return CGSize(width: w, height: h)
		}
		if let viewBox = viewBox(in: svgTag) {
			return CGSize(
				width: explicit.width ?? viewBox.width,
				height: explicit.height ?? viewBox.height
			)
		}
		if let w = explicit.width, let h = explicit.height {
			return CGSize(width: w, height: h)
		}
		return nil
	}

	private static let openTagPattern = try! NSRegularExpression(
		pattern: #"<svg\b[^>]*>"#, options: .caseInsensitive
	)

	private static func openSVGTag(in svg: String) -> String? {
		let ns = svg as NSString
		guard let match = openTagPattern.firstMatch(in: svg, range: NSRange(location: 0, length: ns.length)) else { return nil }
		return ns.substring(with: match.range)
	}

	private static func explicitDimensions(in tag: String) -> (width: Double?, height: Double?) {
		(width: numericAttribute("width", in: tag),
		 height: numericAttribute("height", in: tag))
	}

	/// Parses a numeric attribute, ignoring trailing units (px, pt, %, em, rem, ex).
	private static func numericAttribute(_ name: String, in tag: String) -> Double? {
		let pattern = try! NSRegularExpression(
			pattern: "\\b\(name)=[\"']([0-9.]+)(?:px|pt|em|rem|ex|%)?[\"']",
			options: .caseInsensitive)
		let ns = tag as NSString
		guard let match = pattern.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)) else { return nil }
		return Double(ns.substring(with: match.range(at: 1)))
	}

	/// `viewBox="minX minY width height"` — accepts spaces or commas as separators.
	private static func viewBox(in tag: String) -> (width: Double, height: Double)? {
		let pattern = try! NSRegularExpression(
			pattern: #"\bviewBox=["']([^"']+)["']"#, options: .caseInsensitive)
		let ns = tag as NSString
		guard let match = pattern.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)) else { return nil }
		let raw = ns.substring(with: match.range(at: 1))
		let parts = raw
			.replacingOccurrences(of: ",", with: " ")
			.split(separator: " ")
			.compactMap { Double($0) }
		guard parts.count >= 4, parts[2] > 0, parts[3] > 0 else { return nil }
		return (parts[2], parts[3])
	}
}

extension URL {
	/// True when the URL's path component ends in `.svg` (ignoring query/fragment).
	var isSVGImage: Bool {
		let path = pathExtension.lowercased()
		if path == "svg" || path == "svgz" { return true }
		// Some servers expose SVGs through a path that contains `.svg` but with
		// a different extension, e.g. `…/file.svg.gz`. Be conservative: only
		// match a true `.svg` segment in the path.
		return self.path.lowercased().contains(".svg/")
	}
}
