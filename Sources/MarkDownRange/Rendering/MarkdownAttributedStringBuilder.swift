//
//  MarkdownAttributedStringBuilder.swift
//  MarkDownRange
//
//  Phase 1 of the single-NSTextView renderer. Pure function:
//  [MarkdownBlock] → NSAttributedString. Inline emphasis (bold/italic) is
//  not yet preserved; phase 2 adds a custom inline-style attribute so the
//  builder can reconstruct NSFont weights/traits per run.
//

#if os(macOS)
import AppKit
import SwiftUI

@MainActor
public enum MarkdownAttributedStringBuilder {
	public static func build(blocks: [MarkdownBlock], theme: MarkdownTheme, fontSize: CGFloat, baseURL: URL? = nil, availableWidth: CGFloat? = nil) -> NSAttributedString {
		let context = MarkdownRenderContext(theme: theme, fontSize: fontSize, baseURL: baseURL, availableWidth: availableWidth)
		let result = NSMutableAttributedString()
		for (index, block) in blocks.enumerated() {
			append(block, to: result, context: context)
			if index < blocks.count - 1, !result.string.hasSuffix("\n") {
				result.append(NSAttributedString(string: "\n"))
			}
		}
		return result
	}

	static func append(_ block: MarkdownBlock, to out: NSMutableAttributedString, context: MarkdownRenderContext) {
		switch block {
		case .heading(let level, let content, _):
			appendHeading(level: level, content: content, to: out, context: context)
		case .paragraph(let content, _, _):
			appendParagraph(content: content, to: out, context: context)
		case .blockquote(let children, _):
			appendBlockquote(children: children, to: out, context: context)
		case .orderedList(let items, let start, _):
			appendList(items: items, ordered: true, start: start, to: out, context: context)
		case .unorderedList(let items, _):
			appendList(items: items, ordered: false, start: 1, to: out, context: context)
		case .thematicBreak:
			appendThematicBreak(to: out, context: context)
		case .aligned(_, let inner, _):
			append(inner, to: out, context: context)
		case .definitionList(let items, _):
			appendDefinitionList(items: items, to: out, context: context)
		// Non-text blocks render via NSTextAttachment hosting the existing
		// SwiftUI block view, giving us full visual fidelity (syntax
		// highlighting, copy buttons, table layout, image fetching, etc.)
		// inside the single-NSTextView path.
		case .codeBlock, .image, .imageRow, .htmlBlock, .table, .details, .alert, .frontmatter:
			appendBlockAttachment(block, to: out, context: context)
		}
	}
}

struct MarkdownRenderContext {
	let theme: MarkdownTheme
	let fontSize: CGFloat
	let baseURL: URL?
	var availableWidth: CGFloat?
	var listDepth: Int = 0
	var blockquoteDepth: Int = 0
}
#endif
