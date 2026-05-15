//
//  MarkdownAttributedStringBuilder+Inline.swift
//  MarkDownRange
//
//  Converts a SwiftUI AttributedString (as produced by InlineBuilder) into
//  an NSAttributedString. Phase 1: link, underline, strikethrough, baseline,
//  background colour, foreground colour bridge cleanly. Per-run font traits
//  (bold/italic/inline-code) are NOT preserved here — the caller applies a
//  default font for the whole range. Phase 2 will add a custom inline-style
//  attribute so we can reconstruct NSFont traits.
//

#if os(macOS)
import AppKit
import SwiftUI

extension MarkdownAttributedStringBuilder {
	/// Build an NSAttributedString from inline content with a default font.
	/// `defaultColor` is used for runs that don't carry an explicit foreground.
	/// Per-run inline traits (bold/italic/monospaced) are read from the
	/// `inlineFontTraits` attribute and used to derive a font from `font`,
	/// preserving the contextual size/weight (so e.g. bold inside a heading
	/// stays heading-sized).
	static func nsAttributedString(from inline: AttributedString, font: NSFont, defaultColor: NSColor, boldColor: NSColor? = nil) -> NSAttributedString {
		let result = NSMutableAttributedString()
		for run in inline.runs {
			let substring = String(inline[run.range].characters)
			let traits = run.inlineFontTraits ?? []
			let runFont = font.applyingInlineTraits(traits)
			let baseColor = (boldColor != nil && traits.contains(.bold)) ? boldColor! : defaultColor
			var attrs: [NSAttributedString.Key: Any] = [
				.font: runFont,
				.foregroundColor: baseColor,
			]
			if let color = run.foregroundColor { attrs[.foregroundColor] = NSColor(color) }
			if let bg = run.backgroundColor { attrs[.backgroundColor] = NSColor(bg) }
			if let url = run.link { attrs[.link] = url }
			if run.underlineStyle != nil { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
			if run.strikethroughStyle != nil { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
			if let baseline = run.baselineOffset { attrs[.baselineOffset] = baseline }
			result.append(NSAttributedString(string: substring, attributes: attrs))
		}
		return result
	}
}

extension NSFont {
	/// Returns a variant of this font with the requested inline traits applied.
	/// Monospaced switches to the system monospaced family at the same size;
	/// bold and italic go through NSFontManager — descriptor-based
	/// withSymbolicTraits silently no-ops on system fonts that already carry
	/// an explicit weight attribute, which made **emphasis** invisible
	/// inside headings (H3 at .medium got no weight bump from a "bold" trait).
	func applyingInlineTraits(_ traits: InlineFontTraits) -> NSFont {
		guard !traits.isEmpty else { return self }
		var base: NSFont = self
		if traits.contains(.monospaced) {
			base = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
		}
		let manager = NSFontManager.shared
		if traits.contains(.bold) {
			base = manager.convert(base, toHaveTrait: .boldFontMask)
		}
		if traits.contains(.italic) {
			base = manager.convert(base, toHaveTrait: .italicFontMask)
		}
		return base
	}
}
#endif
