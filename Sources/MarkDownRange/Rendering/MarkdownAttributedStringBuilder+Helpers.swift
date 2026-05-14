//
//  MarkdownAttributedStringBuilder+Helpers.swift
//  MarkDownRange
//

#if os(macOS)
import AppKit
import SwiftUI

extension MarkdownAttributedStringBuilder {
	static func bodyNSFont(size: CGFloat, family: MarkdownFontFamily = .system) -> NSFont {
		designedFont(size: size, weight: .regular, family: family)
	}

	static func headingNSFont(level: Int, base: CGFloat, family: MarkdownFontFamily = .system) -> NSFont {
		let scales: [CGFloat] = [2.0, 1.5, 1.25, 1.1, 1.0, 0.875]
		let scale = scales[min(max(level - 1, 0), scales.count - 1)]
		// Headings sit at a notch lighter than full bold so inline **emphasis**
		// inside a heading (which adds the bold symbolic trait) renders one
		// weight heavier and is visually distinguishable.
		let weight: NSFont.Weight = level <= 2 ? .semibold : .medium
		return designedFont(size: base * scale, weight: weight, family: family)
	}

	private static func designedFont(size: CGFloat, weight: NSFont.Weight, family: MarkdownFontFamily) -> NSFont {
		let base = NSFont.systemFont(ofSize: size, weight: weight)
		guard family != .system,
			  let descriptor = base.fontDescriptor.withDesign(family.systemDesign),
			  let font = NSFont(descriptor: descriptor, size: size)
		else { return base }
		return font
	}

	/// Wrap an existing attributed string with a paragraph style, without
	/// stomping per-run attributes that came from inline content.
	static func decorate(_ inner: NSAttributedString, paragraphStyle: NSParagraphStyle) -> NSAttributedString {
		let result = NSMutableAttributedString(attributedString: inner)
		let range = NSRange(location: 0, length: result.length)
		result.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)
		return result
	}

	static func applyParagraphStyle(_ style: NSParagraphStyle, to out: NSMutableAttributedString, range: NSRange) {
		guard range.length > 0 else { return }
		out.addAttribute(.paragraphStyle, value: style, range: range)
	}

	static func applyForegroundColor(_ color: NSColor, to out: NSMutableAttributedString, range: NSRange) {
		guard range.length > 0 else { return }
		out.addAttribute(.foregroundColor, value: color, range: range)
	}

	/// Fill in a default foreground colour only on runs that don't already
	/// have one (so inline link/code/highlight colours survive).
	static func applyDefaultForegroundIfMissing(_ color: NSColor, to out: NSMutableAttributedString, range: NSRange) {
		guard range.length > 0 else { return }
		out.enumerateAttribute(.foregroundColor, in: range, options: []) { existing, subRange, _ in
			if existing == nil { out.addAttribute(.foregroundColor, value: color, range: subRange) }
		}
	}
}
#endif
