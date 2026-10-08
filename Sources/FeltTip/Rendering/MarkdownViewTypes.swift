//
//  MarkdownViewTypes.swift
//  FeltTip
//
//  Small value types shared across the markdown renderers (scroll/caret control
//  and render-timing metrics). Kept renderer-agnostic and cross-platform so any
//  view backend — the WKWebView renderer today, a future iOS port — can use them.
//

import CoreGraphics
import Foundation

/// An image selected from a rendered Markdown document for presentation by the
/// host app. Local references have already crossed the renderer's sandbox
/// boundary check and arrive as authorized file URLs.
public struct MarkdownImageRequest: Equatable, Sendable {
	public let url: URL
	public let altText: String

	public init(url: URL, altText: String) {
		self.url = url
		self.altText = altText
	}
}

/// A scroll request expressed as a fraction of the document's rendered height,
/// paired with a token. The token is what makes the request distinct across
/// state-driven callers — two updates with the same `topFraction` but different
/// tokens both fire, while repeating an unchanged target is a no-op.
public struct MarkdownScrollTarget: Equatable, Sendable {
	public let topFraction: CGFloat
	public let token: Int

	public init(topFraction: CGFloat, token: Int) {
		self.topFraction = topFraction
		self.token = token
	}
}

/// A request to restore a caret or selection at a source (UTF-16) offset, paired
/// with a token so repeated requests for the same offset (e.g. undo then redo
/// back to the same place) all fire instead of being deduped by SwiftUI
/// equality. Used to restore the selection after a host-driven text change such as
/// an undo/redo.
public struct MarkdownCaretTarget: Equatable, Sendable {
	/// UTF-16 length to reselect after undo; zero restores only the caret.
	public let selectionLength: Int
	public let offset: Int
	public let token: Int

	/// Keep the viewport fixed while restoring an undo/redo selection.
	public let preservesScrollPosition: Bool

	public init(offset: Int, token: Int, selectionLength: Int = 0, preservesScrollPosition: Bool = false) {
		self.preservesScrollPosition = preservesScrollPosition
		self.selectionLength = max(0, selectionLength)
		self.offset = offset
		self.token = token
	}
}

/// A request to install a source selection in an editor, paired with a token
/// so switching views can restore the same range repeatedly. Unlike
/// `MarkdownCaretTarget` (undo/redo, focused-editor only), this is intended for
/// editor handoff: the incoming editor applies it even while it is mounting.
/// A zero length represents an insertion point.
public struct MarkdownSelectionTarget: Equatable, Sendable {
	public let range: NSRange
	public let token: Int

	/// Undo can restore a selection without the centering used for pane handoff.
	public let preservesScrollPosition: Bool

	public init(range: NSRange, token: Int, preservesScrollPosition: Bool = false) {
		self.preservesScrollPosition = preservesScrollPosition
		self.range = range
		self.token = token
	}
}

/// Token-gated request to scroll a rendered source position into view —
/// outline/table-of-contents navigation for the web renderer, which maps the
/// offset to the nearest stamped run. Token semantics match
/// `MarkdownCaretTarget`.
public struct MarkdownSourceScrollTarget: Equatable, Sendable {
	public let offset: Int
	public let token: Int

	public init(offset: Int, token: Int) {
		self.offset = offset
		self.token = token
	}
}

/// Per-phase wall-clock timings for a render pass, in milliseconds. Emitted for
/// benchmarking; not meant to drive product behavior.
public struct MarkdownRenderPhases: Sendable {
	public let parse: Double
	public let prefetch: Double
	public let build: Double
	public let commit: Double
	public let initialLayout: Double
	public let total: Double
	public let tookFastPath: Bool
	/// Build-time breakdown by block category. Nil when no metrics were captured.
	public let attachMs: Double?
	public let attachCount: Int?
	public let textMs: Double?
	public let textCount: Int?
	public let yieldMs: Double?
	/// Parse sub-phases (preprocess / Document init / block build / post-process).
	public let parsePreprocessMs: Double?
	public let parseDocInitMs: Double?
	public let parseBlockBuildMs: Double?
	public let parsePostProcessMs: Double?
}
