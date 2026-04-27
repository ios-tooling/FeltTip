//
//  MarkdownAttributedStringBuilder+Lists.swift
//  MarkDownRange
//

#if os(macOS)
import AppKit
import SwiftUI

extension MarkdownAttributedStringBuilder {
	static func appendList(items: [ListItemContent], ordered: Bool, start: Int, to out: NSMutableAttributedString, context: MarkdownRenderContext) {
		var inner = context
		inner.listDepth += 1
		let bodyFont = bodyNSFont(size: context.fontSize)
		let textColor = NSColor(context.theme.textColor)
		let secondaryColor = NSColor(context.theme.secondaryColor)
		let indent = CGFloat(inner.listDepth) * 18

		for (offset, item) in items.enumerated() {
			let marker = listMarker(ordered: ordered, index: start + offset, item: item)
			let para = NSMutableParagraphStyle()
			para.firstLineHeadIndent = indent - 14
			para.headIndent = indent
			out.append(NSAttributedString(string: marker, attributes: [
				.font: bodyFont,
				.foregroundColor: secondaryColor,
				.paragraphStyle: para,
			]))

			let blocks = item.blocks
			let itemStart = out.length
			for child in blocks { append(child, to: out, context: inner) }
			// Stamp the list paragraph style + indent on the item's full range.
			let itemRange = NSRange(location: itemStart, length: out.length - itemStart)
			if itemRange.length > 0 {
				applyParagraphStyle(para, to: out, range: itemRange)
				// Don't override per-run colors set by inline runs; only fill defaults.
				applyDefaultForegroundIfMissing(textColor, to: out, range: itemRange)
			}
		}
	}

	private static func listMarker(ordered: Bool, index: Int, item: ListItemContent) -> String {
		if let checkbox = item.checkbox {
			return checkbox == .checked ? "☑ " : "☐ "
		}
		return ordered ? "\(index). " : "• "
	}
}
#endif
