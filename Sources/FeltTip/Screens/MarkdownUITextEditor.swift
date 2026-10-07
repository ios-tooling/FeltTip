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
	/// SwiftUI skips `update{NS,UI}View` when a representable's stored
	/// properties compare equal to the last render, and a Binding compares by
	/// its snapshot value. That misses a host that changes the text and changes
	/// it back before SwiftUI renders in between (an edit the host immediately
	/// undoes, under load): the body re-evaluates, the value reads as unchanged,
	/// and the editor is left showing text the host no longer holds. A fresh
	/// token per body evaluation makes every host render reach the update,
	/// where the pending-local-text check decides whether the view must change.
	private let hostUpdateToken = UUID()
	var fontSize: CGFloat
	var theme: MarkdownTheme?
	var typewriterMode: Bool = false
	var focusModeEnabled: Bool = false
	var syntaxHighlightingEnabled: Bool = true
	var onScrollFractionChanged: ((Double) -> Void)?
	var scrollTarget: MarkdownScrollTarget?
	var onCursorPositionChanged: ((Int, Int, Int, Int) -> Void)?
	var onSourceEdit: ((String, Int) -> Void)?
	var onSelectionChanged: ((NSRange?) -> Void)?
	var onSourceSelectionChanged: ((NSRange?) -> Void)?
	var mirroredSelection: NSRange?
	var caretTarget: MarkdownCaretTarget?
	var selectionTarget: MarkdownSelectionTarget?

	func makeUIView(context: Context) -> UITextView {
		let textView = MarkdownScrollingTextView()
		textView.onLayout = { [weak coordinator = context.coordinator, weak textView] in
			guard let textView else { return }
			coordinator?.applyScrollTarget(to: textView)
		}
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
		let previousHostText = coordinator.parent.text
		coordinator.parent = self

		// Comparing `textView.text` bridged the whole document on every SwiftUI
		// tick. Decide from host state plus the local edit the delegate already
		// reported, as the macOS editor does.
		if coordinator.shouldReplaceViewText(previousHostText: previousHostText, incomingText: text) {
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
		coordinator.applyScrollTarget(to: textView)
		coordinator.highlightIfNeeded(textView, theme: theme, enabled: syntaxHighlightingEnabled)
		coordinator.applyFocusMode(to: textView)
	}

	func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
}
/// A target received before SwiftUI supplies a viewport must wait for layout.
private final class MarkdownScrollingTextView: UITextView {
	var onLayout: (() -> Void)?

	override func layoutSubviews() {
		super.layoutSubviews()
		onLayout?()
	}
}
#endif
