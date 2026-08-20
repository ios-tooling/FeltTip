//
//  MarkdownPane.swift
//  MarkDownRange
//
//  The two halves of the iOS source/rendered pair, as real view types so both
//  the compact and regular layouts can compose them without either one owning
//  a pile of configuration.
//

#if os(iOS)
import SwiftUI

/// Everything both panes need that isn't a binding.
struct MarkdownPaneContext {
	let theme: MarkdownTheme
	let fontSize: CGFloat
	var typewriterMode: Bool = false
	var baseURL: URL?
	var editablePreview: Bool = false
	var contentReloadToken: Int = 0
	var onCursorPositionChanged: ((Int, Int, Int, Int) -> Void)?
	var onSourceEdit: ((String, Int?) -> Void)?
	var onSourceSelectionChanged: ((NSRange?) -> Void)?
	var onResourceAccessDenied: (() -> Void)?
	var onCheckboxToggle: ((Int, Bool) -> Void)?
	var caretTarget: MarkdownCaretTarget?
	var selectionTarget: MarkdownSelectionTarget?
}

struct RenderedMarkdownPane: View {
	let text: String
	let context: MarkdownPaneContext
	let scrollFraction: Double

	var body: some View {
		var view = MarkdownWebView(
			text: text, theme: context.theme,
			fontSize: context.fontSize, baseURL: context.baseURL)
			.editable(context.editablePreview)
			.contentReloadToken(context.contentReloadToken)
			.initialScrollFraction(scrollFraction)
			.caretTarget(context.caretTarget)
			.selectionTarget(context.selectionTarget)
		if let onSourceEdit = context.onSourceEdit {
			view = view.onSourceEdit(onSourceEdit)
		}
		if let onCheckboxToggle = context.onCheckboxToggle {
			view = view.onCheckboxToggle(onCheckboxToggle)
		}
		if let onResourceAccessDenied = context.onResourceAccessDenied {
			view = view.onResourceAccessDenied(onResourceAccessDenied)
		}
		return view
	}
}

struct SourceMarkdownPane: View {
	@Binding var text: String
	@Binding var selectedHeadingID: String?
	@Binding var scrollFraction: Double
	let context: MarkdownPaneContext
	var onScrollFractionChanged: ((Double) -> Void)?

	var body: some View {
		RawMarkdownScreen(
			text: $text,
			selectedHeadingID: $selectedHeadingID,
			fontSize: context.fontSize,
			onScrollFractionChanged: { fraction in
				scrollFraction = fraction
				onScrollFractionChanged?(fraction)
			},
			syncScrollFraction: scrollFraction,
			typewriterMode: context.typewriterMode,
			theme: context.theme,
			onCursorPositionChanged: context.onCursorPositionChanged,
			onSourceSelectionChanged: context.onSourceSelectionChanged,
			caretTarget: context.caretTarget,
			selectionTarget: context.selectionTarget)
	}
}
#endif
