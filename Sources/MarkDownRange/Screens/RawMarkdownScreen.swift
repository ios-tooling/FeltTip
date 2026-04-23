//
//  RawMarkdownScreen.swift
//  MarkdownRendering
//

import SwiftUI

public struct RawMarkdownScreen: View {
	@Binding var text: String
	@Binding var selectedHeadingID: String?
	var fontSize: CGFloat
	var onVisibleHeadingChanged: ((String?) -> Void)?
	var onScrollFractionChanged: ((Double) -> Void)?
	var syncScrollFraction: Double?
	var typewriterMode: Bool = false
	var theme: MarkdownTheme?
	var onCursorPositionChanged: ((Int, Int, Int, Int) -> Void)?

	public init(
		text: Binding<String>,
		selectedHeadingID: Binding<String?>,
		fontSize: CGFloat,
		onVisibleHeadingChanged: ((String?) -> Void)? = nil,
		onScrollFractionChanged: ((Double) -> Void)? = nil,
		syncScrollFraction: Double? = nil,
		typewriterMode: Bool = false,
		theme: MarkdownTheme? = nil,
		onCursorPositionChanged: ((Int, Int, Int, Int) -> Void)? = nil
	) {
		self._text = text
		self._selectedHeadingID = selectedHeadingID
		self.fontSize = fontSize
		self.onVisibleHeadingChanged = onVisibleHeadingChanged
		self.onScrollFractionChanged = onScrollFractionChanged
		self.syncScrollFraction = syncScrollFraction
		self.typewriterMode = typewriterMode
		self.theme = theme
		self.onCursorPositionChanged = onCursorPositionChanged
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
			theme: theme,
			onCursorPositionChanged: onCursorPositionChanged
		)
		#else
		TextEditor(text: $text)
			.font(.system(size: fontSize, design: .monospaced))
			.foregroundStyle(theme?.textColor ?? .primary)
			.scrollContentBackground(.hidden)
			.background(theme?.backgroundColor ?? Color(.systemBackground))
			.padding()
		#endif
	}
}
