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
	/// Both the symbolic-trait route and NSFontManager are unreliable for SF
	/// System fonts that already carry an explicit weight attribute — the
	/// existing weight wins over a requested "bold" trait, leaving emphasis
	/// invisible inside a heading. Building a fresh system font at an
	/// explicitly heavier weight via NSFont.systemFont(ofSize:weight:) is the
	/// only deterministic approach.
	func applyingInlineTraits(_ traits: InlineFontTraits) -> NSFont {
		guard !traits.isEmpty else { return self }
		let originalWeight = resolvedWeight
		let wantsBold = traits.contains(.bold)
		let wantsItalic = traits.contains(.italic)
		let wantsMono = traits.contains(.monospaced)
		let targetWeight: NSFont.Weight = wantsBold ? nextBolderWeight(from: originalWeight) : originalWeight

		var base: NSFont
		if wantsMono {
			base = NSFont.monospacedSystemFont(ofSize: pointSize, weight: targetWeight)
		} else {
			base = NSFont.systemFont(ofSize: pointSize, weight: targetWeight)
		}

		if wantsItalic {
			let italicDescriptor = base.fontDescriptor.withSymbolicTraits(.italic)
			if let italicFont = NSFont(descriptor: italicDescriptor, size: pointSize) {
				base = italicFont
			}
		}

		return base
	}

	fileprivate var resolvedWeight: NSFont.Weight {
		let traits = fontDescriptor.fontAttributes[.traits] as? [NSFontDescriptor.TraitKey: Any]
		let raw = (traits?[.weight] as? CGFloat) ?? 0
		return NSFont.Weight(rawValue: raw)
	}
}

private func nextBolderWeight(from current: NSFont.Weight) -> NSFont.Weight {
	if current.rawValue < NSFont.Weight.bold.rawValue { return .bold }
	if current.rawValue < NSFont.Weight.heavy.rawValue { return .heavy }
	return .black
}
#endif
