//
//  UXTextViewSupport.swift
//  MarkDownRange
//
//  The handful of spellings that differ between NSTextView and UITextView,
//  so the syntax highlighter and raw editor can be written once.
//

import CrossPlatformKit
#if os(macOS)
	import AppKit

	typealias UXTextView = NSTextView
#else
	import UIKit

	typealias UXTextView = UITextView
#endif

extension UXTextView {
	/// `NSTextView.string` is non-optional; `UITextView.text` is not.
	var sourceString: String {
		#if os(macOS)
			string
		#else
			text ?? ""
		#endif
	}

	/// `NSTextView.textStorage` is optional and `UITextView.textStorage` is
	/// not; both callers want the optional form.
	var uxTextStorage: NSTextStorage? { textStorage }

	var uxLayoutManager: NSLayoutManager? {
		#if os(macOS)
			layoutManager
		#else
			// Reading `layoutManager` on a TextKit 2 view silently drops it
			// into TextKit 1 compatibility mode, which would leave the view in
			// a worse state than not highlighting at all. The raw editor is
			// built with `usingTextLayoutManager: false`, so a nil
			// `textLayoutManager` is the expected case and this is the real
			// TextKit 1 manager; anything else is a caller error.
			textLayoutManager == nil ? layoutManager : nil
		#endif
	}
}
