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
	/// Builds an attributed string from `blocks`. Async so callers can await
	/// without blocking, but internally the loop is synchronous and yields
	/// only once at the end. Intermediate yields previously fed a determinate
	/// progress bar, but each yield drained ~200 ms of main-actor work queued
	/// by the per-attachment `NSHostingController.sizeThatFits` calls — on a
	/// 200-section document that accounted for ~70% of build time. The
	/// overlay is now indeterminate during build; `onProgress` is invoked
	/// only at the end. (The bottleneck is the synchronous SwiftUI sizing —
	/// addressing it would let us re-introduce progress cheaply.)
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
		// Benchmarking instrumentation; rides out via `lastBuildMetrics`.
		var textTotal: Double = 0
		var attachTotal: Double = 0
		var attachCount: Int = 0
		var textCount: Int = 0
		for (index, block) in blocks.enumerated() {
			let isAttachment = block.isAttachmentRendered
			let t0 = CFAbsoluteTimeGetCurrent()
			append(block, to: result, context: context)
			if index < blocks.count - 1, !result.string.hasSuffix("\n") {
				result.append(NSAttributedString(string: "\n"))
			}
			let elapsed = CFAbsoluteTimeGetCurrent() - t0
			if isAttachment {
				attachTotal += elapsed
				attachCount += 1
			} else {
				textTotal += elapsed
				textCount += 1
			}
		}
		onProgress?(1.0)
		let yt0 = CFAbsoluteTimeGetCurrent()
		await Task.yield()
		let yieldTotal = CFAbsoluteTimeGetCurrent() - yt0
		Self.lastBuildMetrics = BuildMetrics(
			attachMs: attachTotal * 1000,
			attachCount: attachCount,
			textMs: textTotal * 1000,
			textCount: textCount,
			yieldMs: yieldTotal * 1000
		)
		return result
	}

	/// Per-category breakdown of the most recent `build` invocation. Read by
	/// the renderer immediately after build returns and folded into the
	/// `MarkdownRenderPhases` callback. Lives at the type level because build
	/// is a static function and we don't want to thread an out-parameter
	/// through every call site.
	public struct BuildMetrics: Sendable {
		public let attachMs: Double
		public let attachCount: Int
		public let textMs: Double
		public let textCount: Int
		public let yieldMs: Double
	}
	public static var lastBuildMetrics: BuildMetrics?

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

extension MarkdownBlock {
	/// Whether this block renders via `appendBlockAttachment` (a SwiftUI
	/// hosted attachment, costed in NSHostingController.sizeThatFits) rather
	/// than inline text. Used by the benchmarking split inside `build`.
	var isAttachmentRendered: Bool {
		switch self {
		case .codeBlock, .image, .imageRow, .figure, .htmlBlock, .table, .details, .alert, .frontmatter:
			return true
		default:
			return false
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
