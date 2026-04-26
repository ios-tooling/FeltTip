//
//  SplitMarkdownScreen.swift
//  MarkdownRendering
//

import SwiftUI

public struct SplitMarkdownScreen: View {
	@Binding var text: String
	@Binding var selectedHeadingID: String?
	let theme: MarkdownTheme
	let fontSize: CGFloat
	var focusModeEnabled: Bool = false
	var typewriterMode: Bool = false
	var onCursorPositionChanged: ((Int, Int, Int, Int) -> Void)?
	var onVisibleSectionChanged: ((String) -> Void)?
	@State private var scrollFraction: Double = 0
	@State private var scrollSource: ScrollSource = .none
	@State private var lockoutTask: Task<Void, Never>?
	@State private var highlightedSectionID: String?
	private static let scrollLockoutMs: Int = 200

	public init(
		text: Binding<String>,
		selectedHeadingID: Binding<String?>,
		theme: MarkdownTheme,
		fontSize: CGFloat,
		focusModeEnabled: Bool = false,
		typewriterMode: Bool = false,
		onCursorPositionChanged: ((Int, Int, Int, Int) -> Void)? = nil,
		onVisibleSectionChanged: ((String) -> Void)? = nil
	) {
		self._text = text
		self._selectedHeadingID = selectedHeadingID
		self.theme = theme
		self.fontSize = fontSize
		self.focusModeEnabled = focusModeEnabled
		self.typewriterMode = typewriterMode
		self.onCursorPositionChanged = onCursorPositionChanged
		self.onVisibleSectionChanged = onVisibleSectionChanged
	}

	public var body: some View {
		#if os(macOS)
		GeometryReader { geo in
			HSplitView {
				RawMarkdownScreen(
					text: $text,
					selectedHeadingID: $selectedHeadingID,
					fontSize: fontSize,
					onVisibleHeadingChanged: { id in
						if let id { onVisibleSectionChanged?(id) }
					},
					onScrollFractionChanged: { fraction in didScroll(.raw, fraction: fraction) },
					syncScrollFraction: scrollSource == .formatted ? scrollFraction : nil,
					typewriterMode: typewriterMode,
					theme: theme,
					onCursorPositionChanged: { line, col, sel, charOffset in
						onCursorPositionChanged?(line, col, sel, charOffset)
						let heading = MarkdownHeading.heading(atCharacterOffset: charOffset, in: text)
						highlightedSectionID = heading?.id ?? "preamble"
					},
					scrollToCharacterOffset: nil
				)
				.frame(minWidth: 150, idealWidth: geo.size.width / 2)
				FormattedMarkdownScreen(
					text: text,
					selectedHeadingID: $selectedHeadingID,
					theme: theme,
					fontSize: fontSize,
					syncScrollFraction: scrollSource == .raw ? scrollFraction : nil,
					focusModeEnabled: focusModeEnabled,
					onScrollFractionChanged: { fraction in didScroll(.formatted, fraction: fraction) },
					highlightedSectionID: highlightedSectionID,
					onVisibleSectionChanged: onVisibleSectionChanged
				)
				.frame(minWidth: 150, idealWidth: geo.size.width / 2)
			}
		}
		#else
		GeometryReader { geometry in
			if geometry.size.width > 600 {
				HStack(spacing: 0) {
					RawMarkdownScreen(text: $text, selectedHeadingID: $selectedHeadingID, fontSize: fontSize, typewriterMode: typewriterMode, theme: theme, onCursorPositionChanged: onCursorPositionChanged)
					Divider()
					FormattedMarkdownScreen(text: text, selectedHeadingID: $selectedHeadingID, theme: theme, fontSize: fontSize, focusModeEnabled: focusModeEnabled)
				}
			} else {
				VStack(spacing: 0) {
					RawMarkdownScreen(text: $text, selectedHeadingID: $selectedHeadingID, fontSize: fontSize, typewriterMode: typewriterMode, theme: theme, onCursorPositionChanged: onCursorPositionChanged)
						.frame(maxHeight: .infinity)
					Divider()
					FormattedMarkdownScreen(text: text, selectedHeadingID: $selectedHeadingID, theme: theme, fontSize: fontSize, focusModeEnabled: focusModeEnabled)
						.frame(maxHeight: .infinity)
				}
			}
		}
		#endif
	}

	private enum ScrollSource { case none, raw, formatted }

	private func didScroll(_ source: ScrollSource, fraction: Double) {
		// Lockout: while one pane is the active source, drop scroll callbacks
		// from the other pane. Programmatic-scroll echoes from the receiving
		// pane otherwise reverse the source and the two ping-pong on every
		// frame. The lockout releases after a quiet period of `scrollLockoutMs`.
		if scrollSource != .none && scrollSource != source { return }
		scrollSource = source
		scrollFraction = fraction
		lockoutTask?.cancel()
		lockoutTask = Task { @MainActor in
			try? await Task.sleep(for: .milliseconds(Self.scrollLockoutMs))
			guard !Task.isCancelled else { return }
			scrollSource = .none
		}
	}
}
