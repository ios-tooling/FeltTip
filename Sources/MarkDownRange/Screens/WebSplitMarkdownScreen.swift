//
//  WebSplitMarkdownScreen.swift
//  MarkDownRange
//
//  Source editor (left) paired with the WebKit-based rendered preview (right),
//  with synced scrolling between the panes. Mirrors SplitMarkdownScreen's
//  scroll-sync machinery but uses MarkdownWebView for the preview, so rich
//  content (mermaid, images, embedded HTML) renders with full fidelity.
//

import SwiftUI

public struct WebSplitMarkdownScreen: View {
	@Binding var text: String
	@Binding var selectedHeadingID: String?
	let theme: MarkdownTheme
	let fontSize: CGFloat
	var focusModeEnabled: Bool = false
	var typewriterMode: Bool = false
	var baseURL: URL?
	var editablePreview: Bool
	var onCursorPositionChanged: ((Int, Int, Int, Int) -> Void)?
	var onVisibleSectionChanged: ((String) -> Void)?
	var initialScrollFraction: Double?
	var onScrollFractionChanged: ((Double) -> Void)?
	/// Host-driven caret restore (undo/redo), applied to both panes so the
	/// insertion point lands at the edit site regardless of which pane is focused.
	var caretTarget: MarkdownCaretTarget?
	/// Forwarded to the web preview so task-list checkboxes stay interactive,
	/// matching SplitMarkdownScreen (which picks this up from the environment).
	@Environment(\.onCheckboxToggle) private var onCheckboxToggle

	public init(
		text: Binding<String>,
		selectedHeadingID: Binding<String?>,
		theme: MarkdownTheme,
		fontSize: CGFloat,
		focusModeEnabled: Bool = false,
		typewriterMode: Bool = false,
		baseURL: URL? = nil,
		editablePreview: Bool = false,
		onCursorPositionChanged: ((Int, Int, Int, Int) -> Void)? = nil,
		onVisibleSectionChanged: ((String) -> Void)? = nil,
		initialScrollFraction: Double? = nil,
		onScrollFractionChanged: ((Double) -> Void)? = nil,
		caretTarget: MarkdownCaretTarget? = nil
	) {
		self._text = text
		self._selectedHeadingID = selectedHeadingID
		self.theme = theme
		self.fontSize = fontSize
		self.focusModeEnabled = focusModeEnabled
		self.typewriterMode = typewriterMode
		self.baseURL = baseURL
		self.editablePreview = editablePreview
		self.onCursorPositionChanged = onCursorPositionChanged
		self.onVisibleSectionChanged = onVisibleSectionChanged
		self.initialScrollFraction = initialScrollFraction
		self.onScrollFractionChanged = onScrollFractionChanged
		self.caretTarget = caretTarget
	}

	#if os(macOS)
	@State private var scrollFraction: Double = 0
	@State private var scrollSource: ScrollSource = .none
	@State private var lockoutTask: Task<Void, Never>?
	@State private var didRestoreScroll = false
	/// Bumped each time the raw pane drives the scroll, so the token-gated
	/// `scrollTarget` on the web preview re-applies the latest fraction.
	@State private var previewScrollToken = 0
	private static let scrollLockoutMs: Int = 200

	public var body: some View {
		HSplitView {
			RawMarkdownScreen(
				text: $text,
				selectedHeadingID: $selectedHeadingID,
				fontSize: fontSize,
				onVisibleHeadingChanged: { id in if let id { onVisibleSectionChanged?(id) } },
				onScrollFractionChanged: { didScroll(.raw, fraction: $0) },
				syncScrollFraction: scrollSource == .formatted ? scrollFraction : nil,
				typewriterMode: typewriterMode,
				theme: theme,
				onCursorPositionChanged: { line, col, sel, offset in onCursorPositionChanged?(line, col, sel, offset) },
				caretTarget: caretTarget
			)
			.frame(minWidth: 150, maxWidth: .infinity)

			preview
				.frame(minWidth: 150, maxWidth: .infinity)
		}
		.onAppear { restoreInitialScroll() }
	}

	private var preview: MarkdownWebView {
		var view = MarkdownWebView(text: text, theme: theme, fontSize: fontSize, baseURL: baseURL)
			.renderMermaid(true)
			.initialScrollFraction(initialScrollFraction)
			.scrollTarget(scrollSource == .raw
				? MarkdownScrollTarget(topFraction: CGFloat(scrollFraction), token: previewScrollToken)
				: nil)
			.onScrollFractionChanged { top, _, _ in didScroll(.formatted, fraction: Double(top)) }
			.caretTarget(caretTarget)
		if let onCheckboxToggle {
			view = view.onCheckboxToggle(onCheckboxToggle)
		}
		if editablePreview {
			view = view.editable(true).onSourceEdit { text = $0 }
		}
		return view
	}

	private enum ScrollSource { case none, raw, formatted }

	/// Lockout mirrors SplitMarkdownScreen: while one pane is the active source,
	/// drop the other pane's echoed scroll callbacks so the two don't ping-pong.
	private func didScroll(_ source: ScrollSource, fraction: Double) {
		if scrollSource != .none && scrollSource != source { return }
		scrollSource = source
		scrollFraction = fraction
		onScrollFractionChanged?(fraction)
		if source == .raw { previewScrollToken += 1 }
		lockoutTask?.cancel()
		lockoutTask = Task { @MainActor in
			try? await Task.sleep(for: .milliseconds(Self.scrollLockoutMs))
			guard !Task.isCancelled else { return }
			scrollSource = .none
		}
	}

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
	#else
	public var body: some View {
		// MarkdownWebView is macOS-only; fall back to the NSTextView split.
		SplitMarkdownScreen(
			text: $text,
			selectedHeadingID: $selectedHeadingID,
			theme: theme,
			fontSize: fontSize,
			focusModeEnabled: focusModeEnabled,
			typewriterMode: typewriterMode,
			onCursorPositionChanged: onCursorPositionChanged,
			onVisibleSectionChanged: onVisibleSectionChanged,
			initialScrollFraction: initialScrollFraction,
			onScrollFractionChanged: onScrollFractionChanged
		)
	}
	#endif
}
