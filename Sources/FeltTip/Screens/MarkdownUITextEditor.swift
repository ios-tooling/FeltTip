//
//  MarkdownUITextEditor.swift
//  FeltTip
//
//  iOS raw source editor. The macOS side is MarkdownTextEditor (NSTextView in
//  an NSScrollView with a line-number ruler); this is the UIKit counterpart,
//  which UITextView gives us with its own scroll view built in.
//
//  Uses a stock (TextKit 2) UITextView. The original plan was to force
//  TextKit 1 so MarkdownSyntaxHighlighter's temporary attributes could be
//  shared verbatim — but temporary attributes turn out to be AppKit-only, with
//  no UIKit equivalent on either TextKit generation. iOS therefore colors
//  through the text storage (see MarkdownHighlightSink), which works
//  identically under TextKit 2, so there is nothing left to gain by opting out
//  of it.
//

#if os(iOS)
import CrossPlatformKit
import SwiftUI
import UIKit

struct MarkdownUITextEditor: UIViewRepresentable {
	@Binding var text: String
	var fontSize: CGFloat
	var theme: MarkdownTheme?
	var typewriterMode: Bool = false
	var focusModeEnabled: Bool = false
	var syntaxHighlightingEnabled: Bool = true
	var onScrollFractionChanged: ((Double) -> Void)?
	var syncScrollFraction: Double?
	var scrollTarget: MarkdownScrollTarget?
	var onCursorPositionChanged: ((Int, Int, Int, Int) -> Void)?
	var onSourceEdit: ((String, Int) -> Void)?
	var onSelectionChanged: ((NSRange?) -> Void)?
	var onSourceSelectionChanged: ((NSRange?) -> Void)?
	var mirroredSelection: NSRange?
	var caretTarget: MarkdownCaretTarget?
	var selectionTarget: MarkdownSelectionTarget?

	func makeUIView(context: Context) -> UITextView {
		let textView = UITextView()
		textView.delegate = context.coordinator
		textView.alwaysBounceVertical = true
		textView.keyboardDismissMode = .interactive
		textView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
		// The source pane is markdown, not prose: the software keyboard's
		// helpfulness actively corrupts it. Smart quotes turn "" into "",
		// smart dashes turn -- into an em dash, and autocapitalization
		// rewrites list markers — each of which silently changes the source.
		textView.autocorrectionType = .no
		textView.autocapitalizationType = .none
		textView.smartQuotesType = .no
		textView.smartDashesType = .no
		textView.smartInsertDeleteType = .no
		textView.spellCheckingType = .no
		textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
		textView.text = text
		context.coordinator.lineIndex.rebuild(for: text)
		context.coordinator.applyTheme(to: textView, theme: theme)
		context.coordinator.highlight(textView, theme: theme, enabled: syntaxHighlightingEnabled)
		return textView
	}

	func updateUIView(_ textView: UITextView, context: Context) {
		let coordinator = context.coordinator
		coordinator.parent = self

		if textView.text != text {
			coordinator.replaceText(with: text, in: textView)
		}
		if textView.font?.pointSize != fontSize {
			textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
			coordinator.invalidateHighlighting()
		}
		coordinator.applyTheme(to: textView, theme: theme)
		coordinator.applyCaretTarget(to: textView)
		coordinator.applySelectionTarget(to: textView)
		coordinator.applyMirroredSelection(to: textView)
		coordinator.applySyncScrollFraction(to: textView)
		coordinator.applyScrollTarget(to: textView)
		coordinator.highlightIfNeeded(textView, theme: theme, enabled: syntaxHighlightingEnabled)
		coordinator.applyFocusMode(to: textView)
	}

	func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
}
#endif
