//
//  MarkdownHighlightSink.swift
//  MarkDownRange
//
//  Where the syntax highlighter puts color.
//
//  macOS colors the source through `NSLayoutManager` temporary attributes, so
//  highlighting never dirties the text storage — that's what keeps it off the
//  undo stack and out of the edit-notification path.
//
//  UIKit has no temporary-attribute API at all; `addTemporaryAttribute`,
//  `removeTemporaryAttribute`, and `setTemporaryAttributes` are AppKit-only.
//  So iOS writes color into the text storage instead, which is where the
//  highlighter already puts the font attribute on both platforms. Attribute
//  edits made directly on the storage don't register with the text view's undo
//  manager and don't fire `textViewDidChange`, so the properties that matter
//  still hold. The cost is that clearing has to repaint the base color rather
//  than simply dropping an overlay.
//

import CoreGraphics
import CrossPlatformKit
import Foundation
#if os(macOS)
	import AppKit
#else
	import UIKit
#endif

struct MarkdownHighlightSink {
	let textStorage: NSTextStorage
	#if os(macOS)
	let layoutManager: NSLayoutManager
	#endif

	/// Reset `range` to the theme's ordinary body color, discarding any color
	/// a previous pass applied.
	func resetColor(in range: NSRange, base: UXColor) {
		#if os(macOS)
			layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
		#else
			// Removing the attribute outright would leave the run with no color
			// of its own, which renders as the system default rather than the
			// theme's text color. Paint the base explicitly instead.
			textStorage.addAttribute(.foregroundColor, value: base, range: range)
		#endif
	}

	func setColor(_ color: UXColor, in range: NSRange) {
		#if os(macOS)
			layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: range)
		#else
			textStorage.addAttribute(.foregroundColor, value: color, range: range)
		#endif
	}

	func setBackground(_ color: UXColor, in range: NSRange) {
		#if os(macOS)
			layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range)
		#else
			textStorage.addAttribute(.backgroundColor, value: color, range: range)
		#endif
	}

	func clearBackground(in range: NSRange) {
		#if os(macOS)
			layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
		#else
			textStorage.removeAttribute(.backgroundColor, range: range)
		#endif
	}
}

extension UXTextView {
	/// A sink over this view's storage, or nil when the view has no storage
	/// (and, on macOS, no layout manager) to write through.
	var highlightSink: MarkdownHighlightSink? {
		guard let textStorage = uxTextStorage else { return nil }
		#if os(macOS)
			guard let layoutManager = uxLayoutManager else { return nil }
			return MarkdownHighlightSink(textStorage: textStorage, layoutManager: layoutManager)
		#else
			return MarkdownHighlightSink(textStorage: textStorage)
		#endif
	}
}
