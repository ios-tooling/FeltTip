//
//  MarkdownWebView.swift
//  MarkDownRange
//
//  WKWebView-backed renderer for the styled view, rendering through the same
//  `MarkdownHTMLRenderer` used for HTML/PDF export. When `editable` is on it
//  turns the page into a contentEditable surface and maps edits back to the
//  Markdown source via per-run `data-s` offsets (the DOM twin of the
//  NSTextView path's `.markdownSourceOffset`).
//
//  Edit bridge invariants: every splice is verified against the source (the
//  replaced text for real ranges, and the surrounding run text for all edits —
//  insertions have nothing else to check); the page shifts its own `data-s`
//  stamps after each in-place edit so later edits map from fresh offsets; and
//  any rejected or unmappable edit triggers a resync re-render, because the
//  browser may already have mutated the DOM. Edits the bridge can't map
//  (inside code/tables, style commands, structural list edits) are vetoed in
//  `beforeinput` so the source is never corrupted.
//
//  Split across files: Coordinator lifecycle in MarkdownWebViewCoordinator,
//  the edit-message bridge in MarkdownWebViewEditBridge, injected JS in
//  Resources/*.js via MarkdownWebViewScripts, and the local-resource scheme
//  handler in MarkdownWebViewSchemeHandler.
//

import CrossPlatformKit
import SwiftUI
import WebKit
#if os(macOS)
	import AppKit
#else
	import UIKit
#endif

public struct MarkdownWebView: UXViewRepresentable {
	@Environment(\.markdownLinkAccessScope) var linkAccessScope
	@Environment(\.colorScheme) private var colorScheme

	/// The theme with dynamic colors flattened against the live color scheme.
	/// Resolved here, on the main actor, because the renderer runs on an actor
	/// where iOS would resolve them against the light-mode default.
	var resolvedTheme: MarkdownTheme { theme.resolved(for: colorScheme) }
	@Environment(\.markdownLinkHandler) private var hostLinkHandler

	/// The host's handler, or the platform default when none was supplied.
	@MainActor var linkHandler: any MarkdownLinkHandler {
		hostLinkHandler ?? DefaultMarkdownLinkHandler.shared
	}
	let text: String
	let theme: MarkdownTheme
	let fontSize: CGFloat
	var baseURL: URL?
	var isEditable = false
	var onSourceEdit: ((String, Int?) -> Void)?
	var onCheckboxToggle: ((Int, Bool) -> Void)?
	/// Called when the user asks to inspect a sufficiently large rendered image.
	/// The renderer validates local/remote/data URLs before crossing this seam.
	var onOpenImage: ((MarkdownImageRequest) -> Void)?
	/// When true (and not editing), the ~3 MB mermaid engine is embedded inline
	/// so mermaid code blocks render as diagrams. Off by default — the QuickLook
	/// extension's sandbox can't load a payload that large (it crashes the
	/// preview), so only the in-app web renderer opts in.
	var renderMermaid = false
	/// Remote subresources are blocked by the generated page's CSP unless a host
	/// deliberately opts in. Opening an untrusted Markdown file must not silently
	/// turn an image URL into a tracking request.
	var allowsRemoteResources = false
	/// Called when a local resource (e.g. an image) couldn't be read because the
	/// sandbox hasn't granted access to its folder. The host uses this to offer
	/// the user a folder-access grant.
	var onResourceAccessDenied: (() -> Void)?
	/// Bumping this forces a reload even when nothing else changed — used after
	/// the host grants folder access so blocked images re-fetch.
	var contentReloadToken = 0
	/// Reports the page's scroll position (top/visible/content fractions, matching
	/// `MarkdownTextView`'s semantics) so a host can drive synced scrolling.
	var onScrollFractionChanged: (@MainActor @Sendable (CGFloat, CGFloat, CGFloat) -> Void)?
	/// Drive the page so `topFraction` sits at the viewport center; token-gated.
	var scrollTarget: MarkdownScrollTarget?
	/// Apply a relative pixel scroll from outside; token-gated.
	var scrollDelta: MarkdownScrollDelta?
	/// Scroll a source offset's rendered run into view (token-gated). Drives
	/// outline/table-of-contents navigation.
	var sourceScrollTarget: MarkdownSourceScrollTarget?
	/// Apply this fraction (0…1 of scrollable height) once, after the first render.
	var initialScrollFraction: Double?
	/// Place the caret at a source offset (token-gated). Used by the host to
	/// restore the insertion point after an undo/redo re-renders the page.
	var caretTarget: MarkdownCaretTarget?
	/// Reports the selected source range when this (focused) page's selection
	/// changes; nil for a collapsed selection. Feeds cross-pane mirroring.
	var onSelectionChanged: ((NSRange?) -> Void)?
	/// Reports the exact focused source range, including zero-length insertion
	/// points, for transferring selection between editor modes.
	var onSourceSelectionChanged: ((NSRange?) -> Void)?
	/// A selection made in the OTHER pane, shown here as a highlight overlay
	/// (CSS custom highlight — the page's real selection is untouched).
	var mirroredSelection: NSRange?
	/// Token-gated source selection installed when this view takes over from
	/// another editor mode.
	var selectionTarget: MarkdownSelectionTarget?
	/// Optional first-render work started by the host before this view mounts.
	/// It is ignored unless every render-affecting input still matches.
	var preparedInitialRender: MarkdownPreparedWebRender?
	/// Reports the first render's lifecycle. `0` means HTML generation started,
	/// `0.25` means HTML is ready and navigation began, `0.75` means WebKit
	/// committed the navigation, and `nil` means loading finished (or failed). This is a
	/// deliberately one-shot hook for host loading UI and performance tracing,
	/// not a callback for ordinary edit-driven re-renders.
	var onInitialRenderProgress: (@MainActor @Sendable (Double?) -> Void)?
	/// Called only after the initial page and its edit bridge are live. Unlike
	/// the terminal progress callback, this never fires for a failed navigation.
	var onInitialRenderReady: (@MainActor @Sendable () -> Void)?

	public init(text: String, theme: MarkdownTheme, fontSize: CGFloat, baseURL: URL? = nil) {
		self.text = text
		self.theme = theme
		self.fontSize = fontSize
		self.baseURL = baseURL
	}

	/// Turn the page into a contentEditable surface that writes edits back to
	/// the Markdown source (see `onSourceEdit`).
	public func editable(_ flag: Bool) -> Self {
		var copy = self
		copy.isEditable = flag
		return copy
	}

	/// Receives the rewritten Markdown after a styled-view edit is mapped back,
	/// plus the post-edit caret offset (UTF-16, into the new source) when the
	/// splicer knows it. Hosts deriving undo state by diffing old→new text
	/// can't localize an edit made of repeated characters; the hint resolves
	/// that ambiguity.
	public func onSourceEdit(_ callback: @escaping (String, Int?) -> Void) -> Self {
		var copy = self
		copy.onSourceEdit = callback
		return copy
	}

	/// Makes task-list checkboxes clickable; the callback receives the toggled
	/// checkbox's document-wide index and its new checked state. Used by the
	/// QuickLook preview to write the change back to the file.
	public func onCheckboxToggle(_ callback: @escaping (Int, Bool) -> Void) -> Self {
		var copy = self
		copy.onCheckboxToggle = callback
		return copy
	}

	/// Adds an accessible expand button to large rendered images and enables a
	/// pinch-out gesture over them. The host decides how to present the image.
	public func onOpenImage(_ callback: @escaping (MarkdownImageRequest) -> Void) -> Self {
		var copy = self
		copy.onOpenImage = callback
		return copy
	}

	/// Opt in to rendering mermaid code blocks as diagrams (embeds the engine).
	/// Not safe in the QuickLook extension — see `renderMermaid`.
	public func renderMermaid(_ flag: Bool) -> Self {
		var copy = self
		copy.renderMermaid = flag
		return copy
	}

	/// Permit HTTP(S) images/media for a trusted document. Off by default.
	public func allowRemoteResources(_ flag: Bool) -> Self {
		var copy = self
		copy.allowsRemoteResources = flag
		return copy
	}

	/// Called when a local resource couldn't be read for lack of sandbox access.
	public func onResourceAccessDenied(_ callback: @escaping () -> Void) -> Self {
		var copy = self
		copy.onResourceAccessDenied = callback
		return copy
	}

	/// Force a reload (e.g. after the host grants folder access) by bumping this.
	public func contentReloadToken(_ token: Int) -> Self {
		var copy = self
		copy.contentReloadToken = token
		return copy
	}

	/// Subscribe to scroll-viewport changes (top/visible/content fractions),
	/// matching `MarkdownTextView.onScrollFractionChanged` so the two can be
	/// synced against each other in a split.
	public func onScrollFractionChanged(_ callback: @escaping @MainActor @Sendable (CGFloat, CGFloat, CGFloat) -> Void) -> Self {
		var copy = self
		copy.onScrollFractionChanged = callback
		return copy
	}

	/// Drive the page's scroll position from outside (e.g. a synced source pane).
	/// Bumping the target's `token` triggers the scroll; same token is ignored.
	public func scrollTarget(_ target: MarkdownScrollTarget?) -> Self {
		var copy = self
		copy.scrollTarget = target
		return copy
	}

	/// Apply a relative pixel scroll delta from outside (token-gated).
	public func scrollDelta(_ delta: MarkdownScrollDelta?) -> Self {
		var copy = self
		copy.scrollDelta = delta
		return copy
	}

	/// Scroll the run rendering `target.offset` into view (token-gated).
	/// Used for outline/table-of-contents navigation.
	public func scrollToSourceOffset(_ target: MarkdownSourceScrollTarget?) -> Self {
		var copy = self
		copy.sourceScrollTarget = target
		return copy
	}

	/// Apply `fraction` (0…1 of scrollable height) once, after the first render.
	public func initialScrollFraction(_ fraction: Double?) -> Self {
		var copy = self
		copy.initialScrollFraction = fraction
		return copy
	}

	/// Restore the caret to a source offset after a host-driven re-render
	/// (undo/redo). Token-gated so the same offset re-applies on demand.
	public func caretTarget(_ target: MarkdownCaretTarget?) -> Self {
		var copy = self
		copy.caretTarget = target
		return copy
	}

	/// Reports selection changes as source ranges (nil when collapsed).
	public func onSelectionChanged(_ callback: @escaping (NSRange?) -> Void) -> Self {
		var copy = self
		copy.onSelectionChanged = callback
		return copy
	}

	/// Reports the mapped source selection, preserving collapsed insertion
	/// points as zero-length ranges. Nil means the DOM position is unmappable.
	public func onSourceSelectionChanged(_ callback: @escaping (NSRange?) -> Void) -> Self {
		var copy = self
		copy.onSourceSelectionChanged = callback
		return copy
	}

	/// Show the other pane's selection as a non-invasive highlight overlay.
	public func mirroredSelection(_ range: NSRange?) -> Self {
		var copy = self
		copy.mirroredSelection = range
		return copy
	}

	/// Install a token-gated source selection when this editor is mounted.
	public func selectionTarget(_ target: MarkdownSelectionTarget?) -> Self {
		var copy = self
		copy.selectionTarget = target
		return copy
	}

	/// Reuse a styled render the host started before SwiftUI mounted WKWebView.
	public func preparedInitialRender(_ render: MarkdownPreparedWebRender?) -> Self {
		var copy = self
		copy.preparedInitialRender = render
		return copy
	}

	/// Observe the one-shot initial styled render. Hosts can combine this with
	/// their own source parsing to define an end-to-end document-ready point.
	public func onInitialRenderProgress(
		_ callback: @escaping @MainActor @Sendable (Double?) -> Void
	) -> Self {
		var copy = self
		copy.onInitialRenderProgress = callback
		return copy
	}

	public func onInitialRenderReady(
		_ callback: @escaping @MainActor @Sendable () -> Void
	) -> Self {
		var copy = self
		copy.onInitialRenderReady = callback
		return copy
	}

	/// Custom scheme the page loads under so relative local-image paths resolve
	/// to it; `LocalResourceSchemeHandler` reads the files and serves the bytes.
	/// `WKWebView.loadHTMLString` refuses to load `file://` subresources, so a
	/// scheme handler is the supported way to show local images.
	nonisolated static let resourceScheme = "markerlocalres"

	public func makeUXView(context: Context) -> MarkdownWebViewFindHost {
		let config = WKWebViewConfiguration()
		let resourcePolicy = LocalResourceAccessPolicy()
		resourcePolicy.setRoot(baseURL)
		context.coordinator.localResourceAccessPolicy = resourcePolicy
		config.userContentController.add(WeakScriptMessageHandler(context.coordinator), name: "mdedit")
		// Install the editing bridge as document-end user scripts so the first
		// page is interactive as soon as its DOM finishes, without waiting for
		// didFinish followed by several evaluateJavaScript round trips.
		config.userContentController.addUserScript(WKUserScript(
			source: Coordinator.scrollSyncScript, injectionTime: .atDocumentEnd,
			forMainFrameOnly: true))
		config.userContentController.addUserScript(WKUserScript(
			source: Coordinator.linkPreviewScript, injectionTime: .atDocumentEnd,
			forMainFrameOnly: true))
		if onCheckboxToggle != nil {
			config.userContentController.addUserScript(WKUserScript(
				source: Coordinator.checkboxScript, injectionTime: .atDocumentEnd,
				forMainFrameOnly: true))
		}
		config.userContentController.addUserScript(WKUserScript(
			source: Coordinator.imagePresentationScript, injectionTime: .atDocumentEnd,
			forMainFrameOnly: true))
		if onOpenImage != nil {
			config.userContentController.addUserScript(WKUserScript(
				source: "window.__mdSetImagePresentationEnabled && window.__mdSetImagePresentationEnabled(true);",
				injectionTime: .atDocumentEnd,
				forMainFrameOnly: true))
		}
		if isEditable {
			config.userContentController.addUserScript(WKUserScript(
				source: Coordinator.editorScript, injectionTime: .atDocumentEnd,
				forMainFrameOnly: true))
		}
		config.userContentController.addUserScript(WKUserScript(
			source: "window.webkit.messageHandlers.mdedit.postMessage({type:'initialReady'});",
			injectionTime: .atDocumentEnd,
			forMainFrameOnly: true))
		context.coordinator.usesDocumentEndScripts = true
		config.setURLSchemeHandler(
			LocalResourceSchemeHandler(coordinator: context.coordinator, accessPolicy: resourcePolicy),
			forURLScheme: Self.resourceScheme)
		let webView = WKWebView(frame: .zero, configuration: config)
		webView.navigationDelegate = context.coordinator
		#if os(macOS)
			webView.setValue(false, forKey: "drawsBackground")
		#else
			webView.isOpaque = false
			webView.backgroundColor = .clear
			webView.scrollView.backgroundColor = .clear
		#endif
		context.coordinator.webView = webView
		// The host stacks the standard find bar above the web view — hosts
		// route ⌘F to it the same way they would to an NSTextView.
		return MarkdownWebViewFindHost(webView: webView)
	}

	public func updateUXView(_ host: MarkdownWebViewFindHost, context: Context) {
		let webView = host.webView
		context.coordinator.parent = self
		context.coordinator.localResourceAccessPolicy?.setRoot(baseURL)
		// Pick up pending restores before the text-driven reload runs, so
		// `didFinish` places them on the freshly stamped DOM.
		context.coordinator.applyCaretTarget()
		context.coordinator.applySelectionTarget(to: webView)
		context.coordinator.load(into: webView)
		context.coordinator.applyScrollControls(to: webView)
		context.coordinator.applyMirroredSelection(to: webView)
		context.coordinator.currentLineChanges = context.environment.markdownLineChanges
		context.coordinator.applyLineChanges(to: webView)
	}

	public func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
}
