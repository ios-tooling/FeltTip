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
	@State private var isEditing = false
	@State private var editLockoutTask: Task<Void, Never>?
	/// Cross-pane selection mirroring: the focused pane's selection shows as
	/// an inactive highlight in the other.
	@State private var previewMirror: NSRange?
	@State private var rawMirror: NSRange?
	private static let scrollLockoutMs: Int = 200
	private static let editLockoutMs: Int = 700

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
				onSelectionChanged: { range in
					// Any selection activity here makes this the active pane:
					// its own mirror is stale noise regardless of the new
					// selection being empty or not.
					if MarkdownSplitSyncLog.enabled { NSLog("[SplitSync] raw selection -> previewMirror=%@", String(describing: range)) }
					rawMirror = nil
					previewMirror = range
				},
				mirroredSelection: rawMirror,
				caretTarget: caretTarget
			)
			.frame(minWidth: 150, maxWidth: .infinity)

			preview
				.frame(minWidth: 150, maxWidth: .infinity)
		}
		.onAppear { restoreInitialScroll() }
		.onChange(of: text) { _, _ in suspendSyncWhileEditing() }
	}

	/// Typing reflows both panes — the raw editor re-lays-out and structural
	/// styled edits re-render the preview — and that churn reaches the scroll
	/// callbacks looking like scrolling. If it claims sync sourcehood the
	/// panes yank each other around under the caret, so the sync sits out
	/// active editing entirely and resumes after a pause.
	private func suspendSyncWhileEditing() {
		isEditing = true
		scrollSource = .none
		// Edits shift offsets; a stale mirror would highlight the wrong text.
		previewMirror = nil
		rawMirror = nil
		editLockoutTask?.cancel()
		editLockoutTask = Task { @MainActor in
			try? await Task.sleep(for: .milliseconds(Self.editLockoutMs))
			guard !Task.isCancelled else { return }
			isEditing = false
		}
	}

	private var preview: MarkdownWebView {
		var view = MarkdownWebView(text: text, theme: theme, fontSize: fontSize, baseURL: baseURL)
			.renderMermaid(true)
			.initialScrollFraction(initialScrollFraction)
			.scrollTarget(scrollSource == .raw
				? MarkdownScrollTarget(topFraction: CGFloat(scrollFraction), token: previewScrollToken)
				: nil)
			.onScrollFractionChanged { top, _, _ in didScroll(.formatted, fraction: Double(top)) }
			.onSelectionChanged { range in
				if MarkdownSplitSyncLog.enabled { NSLog("[SplitSync] preview selection -> rawMirror=%@", String(describing: range)) }
				previewMirror = nil
				rawMirror = range
			}
			.mirroredSelection(previewMirror)
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
		if isEditing {
			if MarkdownSplitSyncLog.enabled { NSLog("[SplitSync] editing, drop %@ %.4f", "\(source)", fraction) }
			return
		}
		if scrollSource != .none && scrollSource != source {
			if MarkdownSplitSyncLog.enabled { NSLog("[SplitSync] drop %@ %.4f (source %@)", "\(source)", fraction, "\(scrollSource)") }
			return
		}
		// Claiming sourcehood requires genuine movement: a report at (or next
		// to) the already-synced position is an echo of our own sync or layout
		// noise, and driving the other pane from it causes visible snap-backs.
		if scrollSource != source, abs(fraction - scrollFraction) < 0.01 {
			if MarkdownSplitSyncLog.enabled { NSLog("[SplitSync] echo %@ %.4f", "\(source)", fraction) }
			return
		}
		if MarkdownSplitSyncLog.enabled { NSLog("[SplitSync] claim %@ %.4f", "\(source)", fraction) }
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
		// MarkdownWebView is macOS-only; until the iOS port wires up a WebView
		// renderer, the non-macOS split simply shows the raw source editor.
		RawMarkdownScreen(
			text: $text,
			selectedHeadingID: $selectedHeadingID,
			fontSize: fontSize,
			syncScrollFraction: initialScrollFraction,
			typewriterMode: typewriterMode,
			theme: theme,
			onCursorPositionChanged: onCursorPositionChanged
		)
	}
	#endif
}
