//
//  WebSplitMarkdownScreen.swift
//  FeltTip
//
//  Source editor (left) paired with the WebKit-based rendered preview (right),
//  with synced scrolling between the panes. Mirrors SplitMarkdownScreen's
//  scroll-sync machinery but uses MarkdownWebView for the preview, so rich
//  content (mermaid, images, embedded HTML) renders with full fidelity.
//

import SwiftUI

@MainActor
enum MarkdownSplitEditRelay {
	static func forward(
		_ newText: String,
		caret: Int?,
		beginEditing: () -> Void,
		report: ((String, Int?) -> Void)?,
		write: (String) -> Void
	) {
		// The renderer can synchronously publish layout-driven scroll callbacks
		// while the host is accepting this edit. Close the sync gate before the
		// host changes its binding, rather than waiting for SwiftUI's onChange.
		beginEditing()
		if let report { report(newText, caret) } else { write(newText) }
	}
}

/// Suppresses a rendered pane's provisional scroll reports while a host
/// restore is landing. WebKit can report its old offset well after the normal
/// cross-pane lockout expires, especially while a large document is laying
/// out. The guard retires only when the rendered pane reaches the requested
/// neighborhood (or its bounded fallback expires).
struct MarkdownSplitHostRestoreGuard: Equatable {
	private(set) var target: Double?
	static let settleTolerance = 0.08

	mutating func begin(at fraction: Double) {
		target = fraction
	}

	mutating func cancel() {
		target = nil
	}

	/// Returns true while this report belongs to the in-flight host restore.
	/// The report that confirms settlement is consumed too, so it cannot turn
	/// around and drive the already-restored source pane.
	mutating func consumeRenderedReport(_ fraction: Double) -> Bool {
		guard let target else { return false }
		if abs(fraction - target) <= Self.settleTolerance {
			self.target = nil
		}
		return true
	}
}

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
	@State private var settledScrollFraction: Double = 0
	@State private var scrollSource: ScrollSource = .none
	@State private var lockoutTask: Task<Void, Never>?
	@State private var hostRestoreGuard = MarkdownSplitHostRestoreGuard()
	@State private var resizeScrollTarget: MarkdownScrollTarget?
	@State private var resizeScrollToken = 0
	@State private var previewSize: CGSize = .zero
	@State private var resizeRestoreTask: Task<Void, Never>?
	@State private var didRestoreScroll = false
	/// Bumped each time the raw pane drives the scroll, so the token-gated
	/// `scrollTarget` on the web preview re-applies the latest fraction.
	@State private var previewScrollToken = 0
	/// Mirror image for the raw pane: bumped when the rendered pane drives.
	@State private var rawScrollToken = 0
	/// The raw pane's current drive. Held as state rather than derived so it
	/// never flips back to an already-consumed host target once a pane sync
	/// has moved the raw editor elsewhere; late layout replays read it too.
	@State private var rawScrollTarget: MarkdownScrollTarget?
	@State private var isEditing = false
	@State private var editLockoutTask: Task<Void, Never>?
	/// Cross-pane selection mirroring: the focused pane's selection shows as
	/// an inactive highlight in the other.
	@State private var previewMirror: NSRange?
	@State private var rawMirror: NSRange?
	private static let scrollLockoutMs: Int = 200
	private static let hostRestoreTimeoutMs: Int = 2_000
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

			preview
				.frame(minWidth: 150, maxWidth: .infinity)
				.onGeometryChange(for: CGSize.self) { proxy in
					proxy.size
				} action: { size in
					previewSizeChanged(to: size)
				}
		}
		.onAppear { restoreInitialScroll() }
		.onChange(of: scrollTarget) { _, target in
			let resizeWasSettling = resizeRestoreTask != nil
			resizeRestoreTask?.cancel()
			resizeRestoreTask = nil
			resizeScrollTarget = nil
			restoreScroll(to: target)
			if resizeWasSettling, let target {
				scheduleResizeRestore(anchor: Double(target.topFraction))
			}
		}
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

	private func relaySourceEdit(_ newText: String, caret: Int?) {
		MarkdownSplitEditRelay.forward(
			newText,
			caret: caret,
			beginEditing: suspendSyncWhileEditing,
			report: onSourceEdit,
			write: { text = $0 })
	}

	private var preview: MarkdownWebView {
		var view = MarkdownWebView(text: text, theme: theme, fontSize: fontSize, baseURL: baseURL)
			.renderMermaid(true)
			.focusMode(focusModeEnabled)
			.initialScrollFraction(initialScrollFraction)
			.scrollTarget(previewScrollTarget)
			.onScrollFractionChanged { top, _, _ in didScroll(.formatted, fraction: Double(top)) }
			.onScrollTargetApplied { fraction in renderedScrollTargetApplied(Double(fraction)) }
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

	private enum ScrollSource { case none, raw, formatted, host }

	private var effectiveScrollTarget: MarkdownScrollTarget? {
		resizeScrollTarget ?? scrollTarget
	}

	/// Host and pane-sync targets use disjoint token spaces (even and odd).
	/// Both editors deduplicate by token, so sharing a sequence could otherwise
	/// make a pane sync accidentally suppress the next host restore.
	private func hostToken(_ token: Int) -> Int { token &* 2 }
	private func syncToken(_ token: Int) -> Int { token &* 2 &+ 1 }

	private func driveRawPane(to fraction: Double) {
		rawScrollToken += 1
		rawScrollTarget = MarkdownScrollTarget(
			topFraction: CGFloat(fraction), token: syncToken(rawScrollToken))
	}

	private var previewScrollTarget: MarkdownScrollTarget? {
		if scrollSource == .host, let scrollTarget = effectiveScrollTarget {
			return MarkdownScrollTarget(
				topFraction: scrollTarget.topFraction,
				token: hostToken(scrollTarget.token))
		}
		guard scrollSource == .raw else { return nil }
		return MarkdownScrollTarget(
			topFraction: CGFloat(scrollFraction),
			token: syncToken(previewScrollToken))
	}

	/// Lockout mirrors SplitMarkdownScreen: while one pane is the active source,
	/// drop the other pane's echoed scroll callbacks so the two don't ping-pong.
	private func didScroll(_ source: ScrollSource, fraction: Double) {
		if isEditing {
			if MarkdownSplitSyncLog.enabled { NSLog("[SplitSync] editing, drop %@ %.4f", "\(source)", fraction) }
			return
		}
		// WebKit can publish its provisional pre-restore offset after the ordinary
		// lockout expires. Keep consuming rendered reports until it reaches the
		// requested neighborhood. A real source-pane scroll is allowed to cancel
		// the restore immediately so the UI never ignores the user's wheel/trackpad.
		if source == .formatted, hostRestoreGuard.consumeRenderedReport(fraction) {
			if hostRestoreGuard.target == nil { finishHostRestore() }
			return
		}
		if scrollSource == .host {
			guard source == .raw else { return }
			hostRestoreGuard.cancel()
			finishHostRestore()
		}
		if scrollSource != .none && scrollSource != source {
			if MarkdownSplitSyncLog.enabled { NSLog("[SplitSync] drop %@ %.4f (source %@)", "\(source)", fraction, "\(scrollSource)") }
			return
		}
		// Claiming sourcehood requires genuine movement: a report at (or next
		// to) the already-synced position is an echo of our own sync or layout
		// noise, and driving the other pane from it causes visible snap-backs.
		// A single wheel/trackpad step in a very long document can move less
		// than one percent. Treat only effectively identical reports as echoes;
		// the pane-specific drive gates already suppress their own callbacks.
		if scrollSource != source, abs(fraction - scrollFraction) < 0.000_1 {
			if MarkdownSplitSyncLog.enabled { NSLog("[SplitSync] echo %@ %.4f", "\(source)", fraction) }
			return
		}
		if MarkdownSplitSyncLog.enabled { NSLog("[SplitSync] claim %@ %.4f", "\(source)", fraction) }
		scrollSource = source
		scrollFraction = fraction
		onScrollFractionChanged?(fraction)
		if source == .raw { previewScrollToken += 1 }
		if source == .formatted { driveRawPane(to: fraction) }
		lockoutTask?.cancel()
		lockoutTask = Task { @MainActor in
			try? await Task.sleep(for: .milliseconds(Self.scrollLockoutMs))
			guard !Task.isCancelled else { return }
			settledScrollFraction = scrollFraction
			scrollSource = .none
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
		scrollSource = .formatted
		// The preview applies `initialScrollFraction` itself; the raw pane
		// needs a drive to the same place.
		driveRawPane(to: fraction)
		lockoutTask?.cancel()
		lockoutTask = Task { @MainActor in
			try? await Task.sleep(for: .milliseconds(Self.scrollLockoutMs))
			guard !Task.isCancelled else { return }
			scrollSource = .none
		}
	}

	private func renderedScrollTargetApplied(_ fraction: Double) {
		guard let target = hostRestoreGuard.target,
			abs(target - fraction) <= MarkdownSplitHostRestoreGuard.settleTolerance else { return }
		hostRestoreGuard.cancel()
		finishHostRestore()
	}

	private func restoreScroll(to target: MarkdownScrollTarget?) {
		guard let target else { return }
		beginHostRestore(to: target)
	}

	private func beginHostRestore(to target: MarkdownScrollTarget) {
		didRestoreScroll = true
		scrollFraction = Double(target.topFraction)
		settledScrollFraction = scrollFraction
		scrollSource = .host
		rawScrollTarget = MarkdownScrollTarget(
			topFraction: target.topFraction, token: hostToken(target.token))
		hostRestoreGuard.begin(at: scrollFraction)
		lockoutTask?.cancel()
		lockoutTask = Task { @MainActor in
			try? await Task.sleep(for: .milliseconds(Self.hostRestoreTimeoutMs))
			guard !Task.isCancelled else { return }
			hostRestoreGuard.cancel()
			scrollSource = .none
		}
	}

	private func previewSizeChanged(to size: CGSize) {
		guard size.width > 0, size.height > 0 else { return }
		guard previewSize != .zero else {
			previewSize = size
			return
		}
		guard abs(size.width - previewSize.width) > 0.5
			|| abs(size.height - previewSize.height) > 0.5 else { return }
		previewSize = size
		// Both TextKit and WebKit reflow when their pane changes size. Their
		// pixel offsets then describe different source locations even though no
		// scroll event occurred. Reapply the shared normalized viewport after the
		// resize settles; tokenizing it makes both long-lived panes accept the
		// same fraction again, including divider drags.
		scheduleResizeRestore(anchor: settledScrollFraction)
	}

	private func scheduleResizeRestore(anchor: Double) {
		resizeRestoreTask?.cancel()
		resizeRestoreTask = Task { @MainActor in
			try? await Task.sleep(for: .milliseconds(120))
			guard !Task.isCancelled else { return }
			applyResizeRestore(anchor: anchor)
			// A severe width reduction can keep changing TextKit's document frame
			// after the first debounced pass. Reassert the pre-resize anchor with a
			// fresh token after that lazy reflow window; a new resize cancels us.
			try? await Task.sleep(for: .milliseconds(480))
			guard !Task.isCancelled else { return }
			applyResizeRestore(anchor: anchor)
			// WebKit can finish a second, later reflow after a rapid divider
			// reversal. One final token converges that last geometry without a
			// permanent observer or polling loop.
			try? await Task.sleep(for: .milliseconds(900))
			guard !Task.isCancelled else { return }
			applyResizeRestore(anchor: anchor)
			resizeRestoreTask = nil
		}
	}

	private func applyResizeRestore(anchor: Double) {
		resizeScrollToken -= 1
		let target = MarkdownScrollTarget(
			topFraction: anchor, token: resizeScrollToken)
		resizeScrollTarget = target
		beginHostRestore(to: target)
	}

	private func finishHostRestore() {
		lockoutTask?.cancel()
		lockoutTask = nil
		scrollSource = .none
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
			onScrollFractionChanged: onScrollFractionChanged)
	}
	#endif
}
