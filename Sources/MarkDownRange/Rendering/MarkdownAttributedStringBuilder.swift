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
	/// Builds an attributed string from `blocks`. Async so the work can yield
	/// to the main run loop between blocks — each attachment-bearing block
	/// runs NSHostingController.sizeThatFits, which is the dominant cost on
	/// a large document. Yielding lets a `@Observable` progress value tick
	/// the loading overlay's determinate bar instead of jumping 0→100 at
	/// the end. `onProgress` is called after each block with a value in 0...1.
	public static func build(
		blocks: [MarkdownBlock],
		theme: MarkdownTheme,
		fontSize: CGFloat,
		baseURL: URL? = nil,
		availableWidth: CGFloat? = nil,
		onProgress: (@MainActor @Sendable (Double) -> Void)? = nil
	) async -> NSAttributedString {
		let context = MarkdownRenderContext(theme: theme, fontSize: fontSize, baseURL: baseURL, availableWidth: availableWidth)
		let result = NSMutableAttributedString()
		let total = max(blocks.count, 1)
		for (index, block) in blocks.enumerated() {
			append(block, to: result, context: context)
			if index < blocks.count - 1, !result.string.hasSuffix("\n") {
				result.append(NSAttributedString(string: "\n"))
			}
			onProgress?(Double(index + 1) / Double(total))
			// Yield every few blocks so the overlay redraws between
			// attachment measurements. More frequent yields are wasted on
			// fast text-only blocks; less frequent ones make the bar feel
			// jumpy on docs with many tables / code blocks.
			if index % 4 == 3 { await Task.yield() }
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
		case .aligned(let alignment, let inner, _):
			var aligned = context
			aligned.paragraphAlignment = nsAlignment(for: alignment)
			append(inner, to: out, context: aligned)
		case .definitionList(let items, _):
			appendDefinitionList(items: items, to: out, context: context)
		// Non-text blocks render via NSTextAttachment hosting the existing
		// SwiftUI block view, giving us full visual fidelity (syntax
		// highlighting, copy buttons, table layout, image fetching, etc.)
		// inside the single-NSTextView path.
		case .codeBlock, .image, .imageRow, .figure, .htmlBlock, .table, .details, .alert, .frontmatter:
			appendBlockAttachment(block, to: out, context: context)
		}
	}

	/// Maps a SwiftUI `HorizontalAlignment` to an `NSTextAlignment`. The block
	/// parser only ever emits `.center` and `.trailing` from `.aligned`
	/// wrappers; anything else collapses to `.natural` so we don't override the
	/// document's default direction.
	static func nsAlignment(for alignment: HorizontalAlignment) -> NSTextAlignment {
		switch alignment {
		case .center: .center
		case .trailing: .right
		default: .natural
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
	/// Set by an enclosing `.aligned` block so paragraph/heading/attachment
	/// rendering can stamp the alignment onto the underlying paragraph style.
	var paragraphAlignment: NSTextAlignment?
}
#endif
