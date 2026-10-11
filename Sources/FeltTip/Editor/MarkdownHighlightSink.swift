//
//  MarkdownHighlightSink.swift
//  FeltTip
//
//  Where the syntax highlighter (and the raw editor's focus dim and mirrored
//  selection wash) put color.
//
//  macOS colors the source through overlay attributes that never dirty the
//  text storage — that's what keeps highlighting off the undo stack and out
//  of the edit-notification path. On a TextKit 2 view those are
//  `NSTextLayoutManager` rendering attributes; on a TextKit 1 view they are
//  `NSLayoutManager` temporary attributes. The raw editor is always TextKit 2
//  (laying out only the viewport is what makes multi-megabyte documents
//  usable); the TextKit 1 path exists for fixtures that were built that way.
//
//  UIKit has neither API: `addTemporaryAttribute` and friends are AppKit-only
//  and UITextView exposes no rendering attributes. So iOS writes color into
//  the text storage instead, which is where the highlighter already puts the
//  font attribute on both platforms. Attribute edits made directly on the
//  storage don't register with the text view's undo manager and don't fire
//  `textViewDidChange`, so the properties that matter still hold. The cost is
//  that clearing has to repaint the base color rather than simply dropping an
//  overlay.
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
	enum Backend {
		case textKit1(NSLayoutManager)
		case textKit2(NSTextLayoutManager)
	}
	let backend: Backend
	#endif

	/// Reset `range` to the theme's ordinary body color, discarding any color
	/// a previous pass applied.
	func resetColor(in range: NSRange, base: UXColor) {
		#if os(macOS)
			removeOverlay(.foregroundColor, in: range)
		#else
			// Removing the attribute outright would leave the run with no color
			// of its own, which renders as the system default rather than the
			// theme's text color. Paint the base explicitly instead.
			textStorage.addAttribute(.foregroundColor, value: base, range: range)
		#endif
	}

	func setColor(_ color: UXColor, in range: NSRange) {
		#if os(macOS)
			addOverlay(.foregroundColor, value: color, in: range)
		#else
			textStorage.addAttribute(.foregroundColor, value: color, range: range)
		#endif
	}

	func setBackground(_ color: UXColor, in range: NSRange) {
		#if os(macOS)
			addOverlay(.backgroundColor, value: color, in: range)
		#else
			textStorage.addAttribute(.backgroundColor, value: color, range: range)
		#endif
	}

	func clearBackground(in range: NSRange) {
		#if os(macOS)
			removeOverlay(.backgroundColor, in: range)
		#else
			textStorage.removeAttribute(.backgroundColor, range: range)
		#endif
	}

	#if os(macOS)
	/// The overlay color drawn over the character at `index`, or nil when no
	/// pass has colored it (it then draws in the storage's own color).
	func overlayColor(at index: Int) -> NSColor? {
		overlay(.foregroundColor, at: index) as? NSColor
	}

	/// The overlay background drawn behind the character at `index`, if any.
	func overlayBackground(at index: Int) -> NSColor? {
		overlay(.backgroundColor, at: index) as? NSColor
	}

	private func clamped(_ range: NSRange) -> NSRange? {
		let length = textStorage.length
		guard range.location != NSNotFound, range.location <= length else { return nil }
		let clipped = NSRange(location: range.location, length: min(range.length, length - range.location))
		return clipped.length > 0 ? clipped : nil
	}

	private func addOverlay(_ key: NSAttributedString.Key, value: Any, in range: NSRange) {
		guard let range = clamped(range) else { return }
		switch backend {
		case .textKit1(let layoutManager):
			layoutManager.addTemporaryAttribute(key, value: value, forCharacterRange: range)
		case .textKit2(let layoutManager):
			guard let textRange = layoutManager.textContentManager?.textRange(for: range) else { return }
			layoutManager.addRenderingAttribute(key, value: value, for: textRange)
		}
	}

	private func removeOverlay(_ key: NSAttributedString.Key, in range: NSRange) {
		guard let range = clamped(range) else { return }
		switch backend {
		case .textKit1(let layoutManager):
			layoutManager.removeTemporaryAttribute(key, forCharacterRange: range)
		case .textKit2(let layoutManager):
			guard let textRange = layoutManager.textContentManager?.textRange(for: range) else { return }
			layoutManager.removeRenderingAttribute(key, for: textRange)
		}
	}

	private func overlay(_ key: NSAttributedString.Key, at index: Int) -> Any? {
		guard index >= 0, index < textStorage.length else { return nil }
		switch backend {
		case .textKit1(let layoutManager):
			return layoutManager.temporaryAttribute(key, atCharacterIndex: index, effectiveRange: nil)
		case .textKit2(let layoutManager):
			guard let location = layoutManager.textContentManager?.location(atCharacterOffset: index) else {
				return nil
			}
			var value: Any?
			layoutManager.enumerateRenderingAttributes(from: location, reverse: false) { _, attributes, range in
				if range.contains(location) { value = attributes[key] }
				return false
			}
			return value
		}
	}
	#endif
}

extension UXTextView {
	/// A sink over this view's storage, or nil when the view has no storage
	/// (and, on macOS, no layout machinery) to write through.
	var highlightSink: MarkdownHighlightSink? {
		guard let textStorage = uxTextStorage else { return nil }
		#if os(macOS)
			if let textLayoutManager {
				return MarkdownHighlightSink(textStorage: textStorage, backend: .textKit2(textLayoutManager))
			}
			guard let layoutManager = textKit1LayoutManager else { return nil }
			return MarkdownHighlightSink(textStorage: textStorage, backend: .textKit1(layoutManager))
		#else
			return MarkdownHighlightSink(textStorage: textStorage)
		#endif
	}
}
