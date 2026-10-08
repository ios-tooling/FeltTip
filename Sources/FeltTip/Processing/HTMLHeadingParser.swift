//
//  HTMLHeadingParser.swift
//  FeltTip
//

import Foundation
import SwiftUI

/// Detects a standalone `<hN>…</hN>` HTML block and produces a native
/// `.heading` block (optionally wrapped in `.aligned` when the tag carries an
/// `align="…"` attribute). Returns `nil` for HTML that isn't a single heading
/// tag so the caller can leave the block untouched.
enum HTMLHeadingParser {
	static func parse(html: String, id: String) -> MarkdownBlock? {
		let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let match = headingRegex.firstMatch(
			in: trimmed,
			range: NSRange(location: 0, length: (trimmed as NSString).length)
		) else { return nil }
		let ns = trimmed as NSString
		// The regex anchors with ^/$, so a match means the whole block is a
		// single heading — no surrounding markup to preserve.
		let levelString = ns.substring(with: match.range(at: 1))
		guard let level = Int(levelString), (1...6).contains(level) else { return nil }
		let attrs = ns.substring(with: match.range(at: 2))
		let inner = ns.substring(with: match.range(at: 3))
		let text = HTMLAttributeParser.decodeEntities(
			HTMLAttributeParser.collapseWhitespace(HTMLAttributeParser.stripTags(inner))
		).trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else { return nil }

		let heading = MarkdownBlock.heading(level: level, content: InlineContent(text), id: "\(id)-h")
		if let alignment = alignment(in: attrs) {
			return .aligned(alignment: alignment, block: heading, id: id)
		}
		return heading
	}

	private static func alignment(in attrs: String) -> HorizontalAlignment? {
		let ns = attrs as NSString
		guard let match = HTMLAttributeParser.Patterns.align.firstMatch(
			in: attrs, range: NSRange(location: 0, length: ns.length)
		) else { return nil }
		switch ns.substring(with: match.range(at: 1)).lowercased() {
		case "center": return .center
		case "right": return .trailing
		default: return nil
		}
	}

	// Captures: 1=level digit, 2=attributes (may be empty), 3=inner HTML.
	// `[\s\S]` in group 3 keeps multi-line heading bodies intact.
	private static let headingRegex: NSRegularExpression = {
		try! NSRegularExpression(
			pattern: #"^<h([1-6])((?:\s+[^>]*)?)>([\s\S]*?)</h\1\s*>$"#,
			options: [.caseInsensitive]
		)
	}()
}
