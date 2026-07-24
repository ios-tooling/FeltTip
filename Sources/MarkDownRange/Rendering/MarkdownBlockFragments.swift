//
//  MarkdownBlockFragments.swift
//  MarkDownRange
//
//  Per-block render output for incremental page updates. A fragment's
//  `signature` is its HTML with every data-s stamp rewritten relative to the
//  fragment's first stamp — stable across pure source-offset shifts, so an
//  edit early in the document doesn't make every later block look changed.
//

import Foundation

public struct MarkdownBlockFragment: Sendable, Equatable {
	public let html: String
	public let signature: String
	/// The fragment's first absolute data-s stamp; nil for unstamped blocks.
	public let firstStamp: Int?

	init(html: String) {
		self.html = html
		let stamps = Self.stampRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
		guard let first = stamps.first,
		      let firstRange = Range(first.range(at: 1), in: html),
		      let base = Int(html[firstRange]) else {
			self.signature = html
			self.firstStamp = nil
			return
		}
		firstStamp = base
		var rewritten = ""
		var cursor = html.startIndex
		for match in stamps {
			guard let valueRange = Range(match.range(at: 1), in: html),
			      let value = Int(html[valueRange]) else { continue }
			rewritten += html[cursor..<valueRange.lowerBound]
			rewritten += String(value - base)
			cursor = valueRange.upperBound
		}
		rewritten += html[cursor...]
		signature = rewritten
	}

	private static let stampRegex = try! NSRegularExpression(pattern: "data-s=\"(\\d+)\"")
}

extension MarkdownHTMLRenderer {
	/// The body fragment as one rendered string per block, under the same
	/// per-render flags as `renderBodyFragment` (whose output is exactly these
	/// fragments joined).
	public static func renderBlockFragments(
		markdown: String,
		theme: MarkdownTheme = .default,
		fontSize: CGFloat = 16,
		options: MarkdownOptions = .default,
		includeSourceOffsets: Bool = false,
		interactiveCheckboxes: Bool = false
	) -> [MarkdownBlockFragment] {
		let blocks = includeSourceOffsets
			? MarkdownBlockParser.parse(markdown, theme: theme, fontSize: fontSize, trackSourceOffsets: true, options: options)
			: MarkdownBlockParser.parse(markdown, theme: theme, fontSize: fontSize, options: options)
		return $emitSourceOffsets.withValue(includeSourceOffsets) {
			$emitInteractiveCheckboxes.withValue(interactiveCheckboxes) {
				blocks.map { MarkdownBlockFragment(html: renderBlock($0)) }
			}
		}
	}
}
