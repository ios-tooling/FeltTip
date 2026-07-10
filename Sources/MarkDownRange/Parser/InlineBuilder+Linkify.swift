//
//  InlineBuilder+Linkify.swift
//  MarkDownRange
//

import Foundation
import SwiftUI

extension InlineBuilder {
	/// Autolinks scheme-bearing URLs in the assembled attributed string via
	/// `NSDataDetector`. CommonMark and GFM both require this for any `http://`
	/// or `https://` URL that wasn't already wrapped in `<…>` or `[…](…)`.
	mutating func linkifyBareURLs() {
		let plainText = String(result.characters)
		guard !plainText.isEmpty, plainText.contains("://"),
			  let detector = Self.urlDetector else { return }
		let fullRange = NSRange(plainText.startIndex..<plainText.endIndex, in: plainText)
		for match in detector.matches(in: plainText, range: fullRange).reversed() {
			guard let url = match.url,
				  let stringRange = Range(match.range, in: plainText) else { continue }
			applyLink(url: url, sourceRange: stringRange, in: plainText)
		}
	}

	/// GFM § 6.9 — the "www. autolink" extension. A run beginning at `www.`,
	/// containing at least one further period, becomes a link to
	/// `http://<run>`. Trailing punctuation (`?!.,:*_~`) is stripped, and a
	/// trailing `)` is stripped when there are more closing than opening
	/// parens in the run. NSDataDetector doesn't catch `www.` without a
	/// scheme, so this pass fills that specific gap.
	mutating func linkifyWWWPrefix() {
		let plainText = String(result.characters)
		guard plainText.lowercased().contains("www."), let regex = Self.wwwPrefixRegex else { return }
		let fullRange = NSRange(plainText.startIndex..<plainText.endIndex, in: plainText)
		for match in regex.matches(in: plainText, range: fullRange).reversed() {
			guard let stringRange = Range(match.range, in: plainText) else { continue }
			let raw = String(plainText[stringRange])
			let trimmed = Self.trimGFMTrailingPunctuation(raw)
			guard trimmed.count > "www.".count else { continue }
			guard let url = URL(string: "http://\(trimmed)") else { continue }
			let trimmedEnd = plainText.index(stringRange.lowerBound, offsetBy: trimmed.count)
			applyLink(url: url, sourceRange: stringRange.lowerBound..<trimmedEnd, in: plainText)
		}
	}

	/// Convert a `Range<String.Index>` in the plain text to the corresponding
	/// `AttributedString` range, skip if any existing link already covers it
	/// or if the range overlaps monospaced (code-span / `<kbd>`) content, and
	/// otherwise apply the link/colour and record a `LinkInfo`.
	private mutating func applyLink(url: URL, sourceRange: Range<String.Index>, in plainText: String) {
		let startOffset = plainText.distance(from: plainText.startIndex, to: sourceRange.lowerBound)
		let endOffset = plainText.distance(from: plainText.startIndex, to: sourceRange.upperBound)
		let start = result.characters.index(result.startIndex, offsetBy: startOffset)
		let end = result.characters.index(result.startIndex, offsetBy: endOffset)
		let range = start..<end

		for run in result[range].runs {
			if run.link != nil { return }
			// Code spans and `<kbd>` text are verbatim — neither markdown's
			// inline rules nor GFM autolinking apply inside them.
			if let traits = run.inlineFontTraits, traits.contains(.monospaced) { return }
		}

		result[range].link = url
		result[range].foregroundColor = theme.linkColor
		links.append(LinkInfo(url: url.absoluteString, characterOffset: startOffset))
	}

	/// Strip GFM trailing punctuation from a candidate URL. Repeatedly removes
	/// one of `?!.,:*_~` from the tail, and removes a tail `)` when there are
	/// more close-parens than open-parens in the surviving string (the GFM
	/// "balanced parens" rule).
	static func trimGFMTrailingPunctuation(_ text: String) -> String {
		var chars = Array(text)
		let trailable: Set<Character> = ["?", "!", ".", ",", ":", "*", "_", "~"]
		while let last = chars.last {
			if trailable.contains(last) {
				chars.removeLast()
				continue
			}
			if last == ")" {
				let opens = chars.reduce(0) { $1 == "(" ? $0 + 1 : $0 }
				let closes = chars.reduce(0) { $1 == ")" ? $0 + 1 : $0 }
				if closes > opens {
					chars.removeLast()
					continue
				}
			}
			break
		}
		return String(chars)
	}

	// MARK: - Cached regex / detector

	static let urlDetector: NSDataDetector? =
		try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

	/// `www.` followed by at least one `.<segment>` domain component, then an
	/// optional path. Word-boundary anchor on `www` prevents `xwww.foo` from
	/// matching. The path stops at whitespace or `<`/`>` so we don't sweep
	/// surrounding inline HTML into the link.
	static let wwwPrefixRegex: NSRegularExpression? =
		try? NSRegularExpression(
			pattern: #"\bwww\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+(?:/[^\s<>]*)?"#,
			options: [.caseInsensitive]
		)
}
