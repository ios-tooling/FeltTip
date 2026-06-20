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
	/// Scroll position (0…1 of scrollable height) to apply to both panes once
	/// on appear, so switching into split mode keeps the reader's place.
	var initialScrollFraction: Double?
	/// Reports the panes' shared scroll position outward as it changes, so the
	/// host can carry it to the other view modes.
	var onScrollFractionChanged: ((Double) -> Void)?
	@State private var scrollFraction: Double = 0
	@State private var scrollSource: ScrollSource = .none
	@State private var lockoutTask: Task<Void, Never>?
	@State private var didRestoreScroll = false
	@State private var highlightedSectionID: String?
	/// Bumped each time the raw pane drives the scroll, so the token-gated
	/// `scrollTarget` on the native preview re-applies the latest fraction.
	@State private var previewScrollToken = 0
	private static let scrollLockoutMs: Int = 200

	public init(
		text: Binding<String>,
		selectedHeadingID: Binding<String?>,
		theme: MarkdownTheme,
		fontSize: CGFloat,
		focusModeEnabled: Bool = false,
		typewriterMode: Bool = false,
		onCursorPositionChanged: ((Int, Int, Int, Int) -> Void)? = nil,
		onVisibleSectionChanged: ((String) -> Void)? = nil,
		initialScrollFraction: Double? = nil,
		onScrollFractionChanged: ((Double) -> Void)? = nil
	) {
		self._text = text
		self._selectedHeadingID = selectedHeadingID
		self.theme = theme
		self.fontSize = fontSize
		self.focusModeEnabled = focusModeEnabled
		self.typewriterMode = typewriterMode
		self.onCursorPositionChanged = onCursorPositionChanged
		self.onVisibleSectionChanged = onVisibleSectionChanged
		self.initialScrollFraction = initialScrollFraction
		self.onScrollFractionChanged = onScrollFractionChanged
	}

	public var body: some View {
		#if os(macOS)
		// No GeometryReader / geo-derived idealWidth here on purpose: deriving
		// each pane's width from the container's geometry re-invalidates layout
		// on every tick of an animated container resize (e.g. the sidebar
		// collapsing on open), which spins AppKit's update-constraints loop past
		// its per-window limit and crashes. HSplitView already shares width
		// evenly between two `maxWidth: .infinity` panes.
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
			.frame(minWidth: 150, maxWidth: .infinity)
			// Preview pane uses the NSTextView-based renderer (same as the
			// standalone formatted view), not the SwiftUI FormattedMarkdownScreen.
			// The SwiftUI renderer's LazyVStack + per-section GeometryReaders
			// re-lay-out on every synced programmatic scroll, accumulating
			// constraint passes until AppKit raises under sustained scrolling —
			// the split-mode crash. Scroll sync is driven via scrollTarget
			// (incoming) and onScrollFractionChanged (outgoing).
			MarkdownTextView(text: text, theme: theme, fontSize: fontSize)
				.selectedHeading($selectedHeadingID)
				.initialScrollFraction(initialScrollFraction)
				.scrollTarget(scrollSource == .raw
					? MarkdownScrollTarget(topFraction: CGFloat(scrollFraction), token: previewScrollToken)
					: nil)
				.onScrollFractionChanged { top, _, _ in didScroll(.formatted, fraction: Double(top)) }
				.frame(minWidth: 150, maxWidth: .infinity)
		}
		.onAppear { restoreInitialScroll() }
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
		onScrollFractionChanged?(fraction)
		// Re-arm the native preview's token-gated scrollTarget so it follows the
		// raw pane. (Formatted→raw sync uses RawMarkdownScreen.syncScrollFraction.)
		if source == .raw { previewScrollToken += 1 }
		lockoutTask?.cancel()
		lockoutTask = Task { @MainActor in
			try? await Task.sleep(for: .milliseconds(Self.scrollLockoutMs))
			guard !Task.isCancelled else { return }
			scrollSource = .none
		}
	}

	/// Restore both panes to `initialScrollFraction` once on appear. Drives the
	/// raw pane through the formatted→raw sync path; the preview restores via
	/// its own `initialScrollFraction`. The source is released after the lockout
	/// so normal pane-to-pane syncing resumes.
	private func restoreInitialScroll() {
		guard !didRestoreScroll, let fraction = initialScrollFraction else { return }
		didRestoreScroll = true
		scrollFraction = fraction
		scrollSource = .formatted
		lockoutTask?.cancel()
		lockoutTask = Task { @MainActor in
			try? await Task.sleep(for: .milliseconds(Self.scrollLockoutMs))
			guard !Task.isCancelled else { return }
			scrollSource = .none
		}
	}
}
