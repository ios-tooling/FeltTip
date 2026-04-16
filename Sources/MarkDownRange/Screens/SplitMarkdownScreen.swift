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
	@State private var scrollFraction: Double = 0
	@State private var scrollSource: ScrollSource = .none

	public init(
		text: Binding<String>,
		selectedHeadingID: Binding<String?>,
		theme: MarkdownTheme,
		fontSize: CGFloat,
		focusModeEnabled: Bool = false,
		typewriterMode: Bool = false
	) {
		self._text = text
		self._selectedHeadingID = selectedHeadingID
		self.theme = theme
		self.fontSize = fontSize
		self.focusModeEnabled = focusModeEnabled
		self.typewriterMode = typewriterMode
	}

	public var body: some View {
		#if os(macOS)
		GeometryReader { geo in
			HSplitView {
				RawMarkdownScreen(
					text: $text,
					selectedHeadingID: $selectedHeadingID,
					fontSize: fontSize,
					onScrollFractionChanged: { fraction in
						scrollSource = .raw
						scrollFraction = fraction
					},
					syncScrollFraction: scrollSource == .formatted ? scrollFraction : nil,
					typewriterMode: typewriterMode,
					theme: theme
				)
				.frame(minWidth: 150, idealWidth: geo.size.width / 2)
				FormattedMarkdownScreen(
					text: text,
					selectedHeadingID: $selectedHeadingID,
					theme: theme,
					fontSize: fontSize,
					syncScrollFraction: scrollSource == .raw ? scrollFraction : nil,
					focusModeEnabled: focusModeEnabled
				)
				.frame(minWidth: 150, idealWidth: geo.size.width / 2)
				.overlay {
					ScrollFractionSync(fraction: $scrollFraction, isSource: true)
						.onChange(of: scrollFraction) {
							if scrollSource != .raw { scrollSource = .formatted }
						}
				}
			}
		}
		.onChange(of: scrollFraction) {
			Task { @MainActor in
				try? await Task.sleep(for: .milliseconds(50))
				scrollSource = .none
			}
		}
		#else
		GeometryReader { geometry in
			if geometry.size.width > 600 {
				HStack(spacing: 0) {
					RawMarkdownScreen(text: $text, selectedHeadingID: $selectedHeadingID, fontSize: fontSize, typewriterMode: typewriterMode, theme: theme)
					Divider()
					FormattedMarkdownScreen(text: text, selectedHeadingID: $selectedHeadingID, theme: theme, fontSize: fontSize, focusModeEnabled: focusModeEnabled)
				}
			} else {
				VStack(spacing: 0) {
					RawMarkdownScreen(text: $text, selectedHeadingID: $selectedHeadingID, fontSize: fontSize, typewriterMode: typewriterMode, theme: theme)
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
}
