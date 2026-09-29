//
//  RawMarkdownScreen.swift
//  MarkdownRendering
//

import SwiftUI

public struct RawMarkdownScreen: View {
	@Environment(\.syntaxHighlightingEnabled) private var syntaxHighlightingEnabled
	@Binding var text: String
	@Binding var selectedHeadingID: String?
	var fontSize: CGFloat
	var onVisibleHeadingChanged: ((String?) -> Void)?
	var onScrollFractionChanged: ((Double) -> Void)?
	var syncScrollFraction: Double?
	var typewriterMode: Bool = false
	var focusModeEnabled: Bool = false
	var theme: MarkdownTheme?
	var onCursorPositionChanged: ((Int, Int, Int, Int) -> Void)?
	var onSourceEdit: ((String, Int) -> Void)?
	var onSelectionChanged: ((NSRange?) -> Void)?
	var onSourceSelectionChanged: ((NSRange?) -> Void)?
	var mirroredSelection: NSRange?
	var scrollToCharacterOffset: Int?
	var caretTarget: MarkdownCaretTarget?
	var selectionTarget: MarkdownSelectionTarget?

	public init(
		text: Binding<String>,
		selectedHeadingID: Binding<String?>,
		fontSize: CGFloat,
		onVisibleHeadingChanged: ((String?) -> Void)? = nil,
		onScrollFractionChanged: ((Double) -> Void)? = nil,
		syncScrollFraction: Double? = nil,
		typewriterMode: Bool = false,
		focusModeEnabled: Bool = false,
		theme: MarkdownTheme? = nil,
		onCursorPositionChanged: ((Int, Int, Int, Int) -> Void)? = nil,
		onSourceEdit: ((String, Int) -> Void)? = nil,
		onSelectionChanged: ((NSRange?) -> Void)? = nil,
		onSourceSelectionChanged: ((NSRange?) -> Void)? = nil,
		mirroredSelection: NSRange? = nil,
		scrollToCharacterOffset: Int? = nil,
		caretTarget: MarkdownCaretTarget? = nil,
		selectionTarget: MarkdownSelectionTarget? = nil
	) {
		self._text = text
		self._selectedHeadingID = selectedHeadingID
		self.fontSize = fontSize
		self.onVisibleHeadingChanged = onVisibleHeadingChanged
		self.onScrollFractionChanged = onScrollFractionChanged
		self.syncScrollFraction = syncScrollFraction
		self.typewriterMode = typewriterMode
		self.focusModeEnabled = focusModeEnabled
		self.theme = theme
		self.onCursorPositionChanged = onCursorPositionChanged
		self.onSourceEdit = onSourceEdit
		self.onSelectionChanged = onSelectionChanged
		self.onSourceSelectionChanged = onSourceSelectionChanged
		self.mirroredSelection = mirroredSelection
		self.scrollToCharacterOffset = scrollToCharacterOffset
		self.caretTarget = caretTarget
		self.selectionTarget = selectionTarget
	}

	public var body: some View {
		#if os(macOS)
		MarkdownTextEditor(
			text: $text,
			selectedHeadingID: $selectedHeadingID,
			fontSize: fontSize,
			onVisibleHeadingChanged: onVisibleHeadingChanged,
			onScrollFractionChanged: onScrollFractionChanged,
			syncScrollFraction: syncScrollFraction,
			typewriterMode: typewriterMode,
			focusModeEnabled: focusModeEnabled,
			theme: theme,
			onCursorPositionChanged: onCursorPositionChanged,
			onSourceEdit: onSourceEdit,
			onSelectionChanged: onSelectionChanged,
			onSourceSelectionChanged: onSourceSelectionChanged,
			mirroredSelection: mirroredSelection,
			scrollToCharacterOffset: scrollToCharacterOffset,
			caretTarget: caretTarget,
			selectionTarget: selectionTarget
		)
		#else
		MarkdownUITextEditor(
			text: $text,
			fontSize: fontSize,
			theme: theme,
			typewriterMode: typewriterMode,
			focusModeEnabled: focusModeEnabled,
			syntaxHighlightingEnabled: syntaxHighlightingEnabled,
			onScrollFractionChanged: onScrollFractionChanged,
			syncScrollFraction: syncScrollFraction,
			onCursorPositionChanged: onCursorPositionChanged,
			onSourceEdit: onSourceEdit,
			onSelectionChanged: onSelectionChanged,
			onSourceSelectionChanged: onSourceSelectionChanged,
			mirroredSelection: mirroredSelection,
			caretTarget: caretTarget,
			selectionTarget: selectionTarget
		)
		.ignoresSafeArea(.container, edges: .bottom)
		#endif
	}
}
