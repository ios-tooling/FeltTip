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
	/// Offset-relative HTML used only when the block diff examines this
	/// fragment as part of a potentially unchanged suffix. Keeping it lazy
	/// avoids duplicating and regex-rewriting every block's HTML during the
	/// initial render and for unchanged prefixes on later renders.
	public var signature: String { signatureCache.value(html: html, base: firstStamp) }
	/// The fragment's first absolute data-s stamp; nil for unstamped blocks.
	public let firstStamp: Int?
	private let signatureCache = SignatureCache()

	init(html: String) {
		self.html = html
		guard let first = Self.stampRegex.firstMatch(
			in: html, range: NSRange(html.startIndex..., in: html)),
		      let firstRange = Range(first.range(at: 1), in: html),
		      let base = Int(html[firstRange]) else {
			self.firstStamp = nil
			return
		}
		firstStamp = base
	}

	private static let stampRegex = try! NSRegularExpression(pattern: "data-s=\"(\\d+)\"")

	/// Test-visible evidence that no signature allocation happened yet.
	var hasCachedSignature: Bool { signatureCache.hasValue }

	public static func == (lhs: Self, rhs: Self) -> Bool {
		// firstStamp and signature are derived entirely from HTML.
		lhs.html == rhs.html
	}

	private final class SignatureCache: @unchecked Sendable {
		private let lock = NSLock()
		private var cached: String?

		var hasValue: Bool {
			lock.withLock { cached != nil }
		}

		func value(html: String, base: Int?) -> String {
			lock.withLock {
				if let cached { return cached }
				guard let base else {
					cached = html
					return html
				}
				let stamps = MarkdownBlockFragment.stampRegex.matches(
					in: html, range: NSRange(html.startIndex..., in: html))
				var rewritten = ""
				rewritten.reserveCapacity(html.utf8.count)
				var cursor = html.startIndex
				for match in stamps {
					guard let valueRange = Range(match.range(at: 1), in: html),
					      let value = Int(html[valueRange]) else { continue }
					rewritten += html[cursor..<valueRange.lowerBound]
					rewritten += String(value - base)
					cursor = valueRange.upperBound
				}
				rewritten += html[cursor...]
				cached = rewritten
				return rewritten
			}
		}
	}
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
