//
//  WebSplitMarkdownScreen.swift
//  FeltTip
//
//  Source editor (left) paired with the WebKit-based rendered preview (right),
//  with synced scrolling between the panes. The split only relays: a scroll in
//  one pane becomes a token-gated drive of the other, and a host restore
//  drives both. Each pane owns its own viewport through layout and resize and
//  suppresses the echo of its own drive, so there is no arbitration here
//  beyond sitting out active editing.
//

import SwiftUI

/// Pane selected by the compact iOS source/rendered switch. Hosts can persist
/// this per document while regular-width layouts continue to show both panes.
public enum MarkdownCompactPane: String, CaseIterable, Identifiable, Sendable {
	case rendered, source
	public var id: Self { self }
	var label: String { self == .rendered ? "Rendered" : "Source" }
}

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
	/// When set, edits from either pane are reported here — with the post-edit
	/// caret offset when known — instead of being written to the `text` binding.
	var onSourceEdit: ((String, Int?) -> Void)?
	var onSourceSelectionChanged: ((NSRange?) -> Void)?
	var onVisibleSectionChanged: ((String) -> Void)?
	var initialCompactPane: MarkdownCompactPane
	/// The pane that receives a host-driven selection handoff. The other pane
	/// mirrors that selection without taking keyboard focus.
	var selectionTargetPane: MarkdownCompactPane
	var onCompactPaneChanged: ((MarkdownCompactPane) -> Void)?
	var initialScrollFraction: Double?
	/// A tokenized host restore applied to both panes. Unlike
	/// `initialScrollFraction`, this can restore the same position each time a
	/// long-lived split view is revealed again.
	var scrollTarget: MarkdownScrollTarget?
	var onScrollFractionChanged: ((Double) -> Void)?
	/// Host-driven caret restore (undo/redo), applied to both panes so the
	/// insertion point lands at the edit site regardless of which pane is focused.
	var caretTarget: MarkdownCaretTarget?
	var selectionTarget: MarkdownSelectionTarget?
	var onResourceAccessDenied: (() -> Void)?
	var contentReloadToken: Int
	var preparedInitialRender: MarkdownPreparedWebRender?
	var onInitialRenderProgress: (@MainActor @Sendable (Double?) -> Void)?
	var onOpenImage: ((MarkdownImageRequest) -> Void)?
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
		onSourceEdit: ((String, Int?) -> Void)? = nil,
		onSourceSelectionChanged: ((NSRange?) -> Void)? = nil,
		onVisibleSectionChanged: ((String) -> Void)? = nil,
		initialCompactPane: MarkdownCompactPane = .rendered,
		selectionTargetPane: MarkdownCompactPane? = nil,
		onCompactPaneChanged: ((MarkdownCompactPane) -> Void)? = nil,
		initialScrollFraction: Double? = nil,
		scrollTarget: MarkdownScrollTarget? = nil,
		onScrollFractionChanged: ((Double) -> Void)? = nil,
		caretTarget: MarkdownCaretTarget? = nil,
		selectionTarget: MarkdownSelectionTarget? = nil,
		onResourceAccessDenied: (() -> Void)? = nil,
		contentReloadToken: Int = 0,
		preparedInitialRender: MarkdownPreparedWebRender? = nil,
		onInitialRenderProgress: (@MainActor @Sendable (Double?) -> Void)? = nil
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
		self.onSourceEdit = onSourceEdit
		self.onSourceSelectionChanged = onSourceSelectionChanged
		self.onVisibleSectionChanged = onVisibleSectionChanged
		self.initialCompactPane = initialCompactPane
		self.selectionTargetPane = selectionTargetPane ?? initialCompactPane
		self.onCompactPaneChanged = onCompactPaneChanged
		self.initialScrollFraction = initialScrollFraction
		self.scrollTarget = scrollTarget
		self.onScrollFractionChanged = onScrollFractionChanged
		self.caretTarget = caretTarget
		self.selectionTarget = selectionTarget
		self.onResourceAccessDenied = onResourceAccessDenied
		self.contentReloadToken = contentReloadToken
		self.preparedInitialRender = preparedInitialRender
		self.onInitialRenderProgress = onInitialRenderProgress
	}

	/// Forwards large-image presentation requests from the rendered pane.
	public func onOpenImage(_ callback: @escaping (MarkdownImageRequest) -> Void) -> Self {
		var copy = self
		copy.onOpenImage = callback
		return copy
	}

	#if os(macOS)
	@State private var scrollFraction: Double = 0
	@State private var didRestoreScroll = false
	/// Each pane's current drive, held as state rather than derived so it
	/// never flips back to an already-consumed host target once a pane sync
	/// has moved that pane elsewhere; late layout replays read it too. Host
	/// restores and pane syncs use disjoint token spaces (even and odd), since
	/// both editors deduplicate by token.
	@State private var rawScrollTarget: MarkdownScrollTarget?
	@State private var previewScrollTarget: MarkdownScrollTarget?
	@State private var syncCounter = 0
	@State private var isEditing = false
	@State private var editLockoutTask: Task<Void, Never>?
	/// Cross-pane selection mirroring: the focused pane's selection shows as
	/// an inactive highlight in the other.
	@State private var previewMirror: NSRange?
	@State private var rawMirror: NSRange?
	private static let editLockoutMs: Int = 700

	public var body: some View {
		HSplitView {
			RawMarkdownScreen(
				text: $text,
				selectedHeadingID: $selectedHeadingID,
				fontSize: fontSize,
				onVisibleHeadingChanged: { id in if let id { onVisibleSectionChanged?(id) } },
				onScrollFractionChanged: { didScroll(.raw, fraction: $0) },
				scrollTarget: rawScrollTarget,
				typewriterMode: typewriterMode,
				focusModeEnabled: focusModeEnabled,
				theme: theme,
				onCursorPositionChanged: { line, col, sel, offset in onCursorPositionChanged?(line, col, sel, offset) },
				onSourceEdit: { new, caret in relaySourceEdit(new, caret: caret) },
				onSelectionChanged: { range in
					// Any selection activity here makes this the active pane:
					// its own mirror is stale noise regardless of the new
					// selection being empty or not.
					if MarkdownSplitSyncLog.enabled { NSLog("[SplitSync] raw selection -> previewMirror=%@", String(describing: range)) }
					rawMirror = nil
					previewMirror = range
				},
				onSourceSelectionChanged: onSourceSelectionChanged,
				mirroredSelection: rawMirror,
				caretTarget: caretTarget,
				selectionTarget: selectionTargetPane == .source ? selectionTarget : nil
			)
			.frame(minWidth: 150, maxWidth: .infinity)

			// Each pane keeps its own normalized viewport through a resize (the
			// raw editor in its coordinator, the page in ScrollSyncScript), so the
			// split only arbitrates user scrolls and host restores.
			preview
				.frame(minWidth: 150, maxWidth: .infinity)
		}
		.onAppear { restoreInitialScroll() }
		.onChange(of: scrollTarget) { _, target in restoreScroll(to: target) }
		.onChange(of: text) { _, _ in suspendSyncWhileEditing() }
	}

	/// Typing reflows both panes — the raw editor re-lays-out and structural
	/// styled edits re-render the preview — and that churn reaches the scroll
	/// callbacks looking like scrolling. If it claims sync sourcehood the
	/// panes yank each other around under the caret, so the sync sits out
	/// active editing entirely and resumes after a pause.
	private func suspendSyncWhileEditing() {
		isEditing = true
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

	private func relaySourceEdit(_ newText: String, caret: Int?) {
		// The renderer can synchronously publish layout-driven scroll callbacks
		// while the host is accepting this edit. Close the sync gate before the
		// host changes its binding, rather than waiting for SwiftUI's onChange.
		suspendSyncWhileEditing()
		if let onSourceEdit { onSourceEdit(newText, caret) } else { text = newText }
	}

	private var preview: MarkdownWebView {
		var view = MarkdownWebView(text: text, theme: theme, fontSize: fontSize, baseURL: baseURL)
			.renderMermaid(true)
			.focusMode(focusModeEnabled)
			.initialScrollFraction(initialScrollFraction)
			.scrollTarget(previewScrollTarget)
			.onScrollFractionChanged { top, _, _ in didScroll(.formatted, fraction: Double(top)) }
			.onSelectionChanged { range in
				if MarkdownSplitSyncLog.enabled { NSLog("[SplitSync] preview selection -> rawMirror=%@", String(describing: range)) }
				previewMirror = nil
				rawMirror = range
			}
			.mirroredSelection(previewMirror)
			.caretTarget(caretTarget)
			.selectionTarget(selectionTargetPane == .rendered ? selectionTarget : nil)
			.contentReloadToken(contentReloadToken)
			.preparedInitialRender(preparedInitialRender)
			.onInitialRenderProgress { onInitialRenderProgress?($0) }
			.onSourceSelectionChanged { onSourceSelectionChanged?($0) }
		if let onResourceAccessDenied {
			view = view.onResourceAccessDenied(onResourceAccessDenied)
		}
		if let onCheckboxToggle {
			view = view.onCheckboxToggle(onCheckboxToggle)
		}
		if let onOpenImage {
			view = view.onOpenImage(onOpenImage)
		}
		if editablePreview {
			view = view.editable(true).onSourceEdit { new, caret in
				relaySourceEdit(new, caret: caret)
			}
		}
		return view
	}

	private enum ScrollSource { case raw, formatted }

	private func hostToken(_ token: Int) -> Int { token &* 2 }

	private func nextSyncTarget(_ fraction: Double) -> MarkdownScrollTarget {
		syncCounter += 1
		return MarkdownScrollTarget(
			topFraction: CGFloat(fraction), token: syncCounter &* 2 &+ 1)
	}

	private func driveRawPane(to fraction: Double) {
		rawScrollTarget = nextSyncTarget(fraction)
	}

	private func drivePreviewPane(to fraction: Double) {
		previewScrollTarget = nextSyncTarget(fraction)
	}

	/// One pane scrolled: drive the other to the same fraction. Each pane
	/// suppresses the echo of its own drive (the raw editor's sync flag and
	/// reported-offset check, the page's `driven` state), so no lockout or
	/// value-based echo filter is needed here; the only thing worth dropping is
	/// the layout churn of active editing.
	private func didScroll(_ source: ScrollSource, fraction: Double) {
		// Persistence follows the active viewport even while cross-pane sync
		// is suspended. Otherwise a short scroll after typing is lost.
		scrollFraction = fraction
		onScrollFractionChanged?(fraction)
		if isEditing {
			if MarkdownSplitSyncLog.enabled { NSLog("[SplitSync] editing, drop %@ %.4f", "\(source)", fraction) }
			return
		}
		if MarkdownSplitSyncLog.enabled { NSLog("[SplitSync] sync from %@ %.4f", "\(source)", fraction) }
		switch source {
		case .raw: drivePreviewPane(to: fraction)
		case .formatted: driveRawPane(to: fraction)
		}
	}

	private func restoreInitialScroll() {
		guard !didRestoreScroll else { return }
		if let scrollTarget {
			restoreScroll(to: scrollTarget)
			return
		}
		guard let fraction = initialScrollFraction else { return }
		didRestoreScroll = true
		scrollFraction = fraction
		// The preview applies `initialScrollFraction` itself; the raw pane
		// needs a drive to the same place.
		driveRawPane(to: fraction)
	}

	/// A host restore drives both panes with the host's token. Neither pane
	/// reports the drive back, so there is nothing to lock out.
	private func restoreScroll(to target: MarkdownScrollTarget?) {
		guard let target else { return }
		didRestoreScroll = true
		scrollFraction = Double(target.topFraction)
		let shared = MarkdownScrollTarget(
			topFraction: target.topFraction, token: hostToken(target.token))
		rawScrollTarget = shared
		previewScrollTarget = shared
	}
	#else
	public var body: some View {
		AdaptiveMarkdownPanes(
			text: $text,
			selectedHeadingID: $selectedHeadingID,
			context: MarkdownPaneContext(
				theme: theme,
				fontSize: fontSize,
				typewriterMode: typewriterMode,
				baseURL: baseURL,
				editablePreview: editablePreview,
				contentReloadToken: contentReloadToken,
				onCursorPositionChanged: onCursorPositionChanged,
				onSourceEdit: onSourceEdit,
				onSourceSelectionChanged: onSourceSelectionChanged,
				onResourceAccessDenied: onResourceAccessDenied,
				onCheckboxToggle: onCheckboxToggle,
				caretTarget: caretTarget,
				selectionTarget: selectionTarget),
			initialPane: initialCompactPane,
			onPaneChanged: onCompactPaneChanged,
			initialScrollFraction: initialScrollFraction,
			scrollTarget: scrollTarget,
			onScrollFractionChanged: onScrollFractionChanged)
	}
	#endif
}
