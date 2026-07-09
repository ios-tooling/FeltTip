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

#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

public struct MarkdownWebView: NSViewRepresentable {
	let text: String
	let theme: MarkdownTheme
	let fontSize: CGFloat
	var baseURL: URL?
	var isEditable = false
	var onSourceEdit: ((String) -> Void)?
	var onCheckboxToggle: ((Int, Bool) -> Void)?
	/// When true (and not editing), the ~3 MB mermaid engine is embedded inline
	/// so mermaid code blocks render as diagrams. Off by default — the QuickLook
	/// extension's sandbox can't load a payload that large (it crashes the
	/// preview), so only the in-app web renderer opts in.
	var renderMermaid = false
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
	/// A selection made in the OTHER pane, shown here as a highlight overlay
	/// (CSS custom highlight — the page's real selection is untouched).
	var mirroredSelection: NSRange?

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

	/// Receives the rewritten Markdown after a styled-view edit is mapped back.
	public func onSourceEdit(_ callback: @escaping (String) -> Void) -> Self {
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

	/// Opt in to rendering mermaid code blocks as diagrams (embeds the engine).
	/// Not safe in the QuickLook extension — see `renderMermaid`.
	public func renderMermaid(_ flag: Bool) -> Self {
		var copy = self
		copy.renderMermaid = flag
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

	/// Show the other pane's selection as a non-invasive highlight overlay.
	public func mirroredSelection(_ range: NSRange?) -> Self {
		var copy = self
		copy.mirroredSelection = range
		return copy
	}

	/// Custom scheme the page loads under so relative local-image paths resolve
	/// to it; `LocalResourceSchemeHandler` reads the files and serves the bytes.
	/// `WKWebView.loadHTMLString` refuses to load `file://` subresources, so a
	/// scheme handler is the supported way to show local images.
	static let resourceScheme = "markerlocalres"

	public func makeNSView(context: Context) -> MarkdownWebViewFindHost {
		let config = WKWebViewConfiguration()
		config.userContentController.add(WeakScriptMessageHandler(context.coordinator), name: "mdedit")
		config.setURLSchemeHandler(LocalResourceSchemeHandler(coordinator: context.coordinator), forURLScheme: Self.resourceScheme)
		let webView = WKWebView(frame: .zero, configuration: config)
		webView.navigationDelegate = context.coordinator
		webView.setValue(false, forKey: "drawsBackground")
		context.coordinator.webView = webView
		// The host stacks the standard find bar above the web view — hosts
		// route ⌘F to it the same way they would to an NSTextView.
		return MarkdownWebViewFindHost(webView: webView)
	}

	public func updateNSView(_ host: MarkdownWebViewFindHost, context: Context) {
		let webView = host.webView
		context.coordinator.parent = self
		// Pick up a pending caret restore (undo/redo) before the text-driven
		// reload runs, so `didFinish` places the caret on the freshly stamped DOM.
		context.coordinator.applyCaretTarget()
		context.coordinator.load(into: webView)
		context.coordinator.applyScrollControls(to: webView)
		context.coordinator.applyMirroredSelection(to: webView)
	}

	public func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

	@MainActor
	public final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
		var parent: MarkdownWebView
		weak var webView: WKWebView?
		private var lastKey: String?
		/// The non-text part of `lastKey`; a mismatch means CSS/config changed
		/// and the page needs a real reload rather than a body swap.
		private var lastConfigSignature: String?
		/// Debounced in-place body update for external text changes (typing in
		/// the raw pane of a split re-renders the preview through here).
		private var pendingSwap: Task<Void, Never>?
		/// The source produced by our own last edit. When the resulting
		/// `session.text` update comes back through `load`, we skip the reload so
		/// the live contentEditable DOM (which already shows the edit) isn't torn
		/// down. Matched on the actual text, not a composite key, so it's robust
		/// against theme-signature churn.
		private var selfEditedText: String?
		/// Last scroll position reported by the page, restored after any reload
		/// so re-renders don't jump to the top.
		/// Internal (not private) so tests can seed it — the page reports it
		/// through a requestAnimationFrame throttle that headless test windows
		/// don't reliably run.
		var lastScrollY: Double = 0
		/// Selection (offset + length; length 0 = caret) to restore after a
		/// structural re-render. Style toggles restore the full selection so
		/// repeated ⌘B/⌘I keep operating on the same text.
		private var pendingSelection: NSRange?
		/// The source the DOM currently reflects. Advanced synchronously on every
		/// edit so rapid edits chain off the right base — `parent.text` lags
		/// because the SwiftUI round-trip back into `updateNSView` is async.
		private var currentSource: String?
		/// Scroll-control tokens already applied, so a state-driven binding that
		/// survives unrelated re-renders doesn't re-scroll.
		private var lastScrollTargetToken: Int?
		private var lastScrollDeltaToken: Int?
		private var lastSourceScrollToken: Int?
		/// Caret-restore token already applied, so a binding that survives
		/// unrelated re-renders doesn't re-place the caret.
		private var lastCaretToken: Int?
		/// `initialScrollFraction` is applied only once, after the first render.
		private var didApplyInitialScroll = false
		/// Logs the edit bridge to the console (every message, splice, and
		/// rejection). Toggle without rebuilding:
		/// `defaults write <bundle-id> MDRDebugEditing -bool true`.
		static let debugEditing = UserDefaults.standard.bool(forKey: "MDRDebugEditing")

		init(parent: MarkdownWebView) {
			self.parent = parent
		}

		private func configSignature() -> String {
			"\(parent.isEditable)|\(parent.onCheckboxToggle != nil)|\(parent.renderMermaid)|\(parent.theme.signature)|\(parent.fontSize)|\(parent.baseURL?.absoluteString ?? "")|\(parent.contentReloadToken)"
		}

		private func renderKey(text: String) -> String {
			"\(configSignature())|\(text.hashValue)"
		}

		func load(into webView: WKWebView) {
			// Our own edit coming back round-trip — the DOM already shows it.
			let key = renderKey(text: parent.text)
			if let edited = selfEditedText, parent.text == edited {
				selfEditedText = nil
				if key == lastKey { return }
			}
			guard key != lastKey else { return }
			// A full (navigating) load is needed for the first render, for
			// config changes (theme/font mean new CSS), for mermaid pages (the
			// embedded engine script doesn't survive a body swap), and for our
			// own structural edits, whose pending caret is placed in
			// `didFinish`. Everything else — the text changing under us, i.e.
			// typing in the raw pane of a split — updates the page in place
			// after a debounce, so the preview neither flashes through a blank
			// navigation nor re-renders on every keystroke.
			let config = configSignature()
			if lastKey == nil || pendingSelection != nil || config != lastConfigSignature
				|| (parent.renderMermaid && !parent.isEditable) {
				pendingSwap?.cancel()
				pendingSwap = nil
				lastKey = key
				lastConfigSignature = config
				log("reload: textLen=\((parent.text as NSString).length)")
				currentSource = parent.text
				loadHTML(for: parent.text, into: webView)
				return
			}
			pendingSwap?.cancel()
			pendingSwap = Task { @MainActor [weak self, weak webView] in
				try? await Task.sleep(for: .milliseconds(250))
				guard !Task.isCancelled, let self, let webView else { return }
				self.pendingSwap = nil
				self.applyBodySwap(into: webView)
			}
		}

		/// Re-render the body and swap it into the loaded page in place.
		/// Reads the freshest `parent` state at fire time — later updates may
		/// have arrived during the debounce.
		private func applyBodySwap(into webView: WKWebView) {
			let text = parent.text
			let key = renderKey(text: text)
			guard key != lastKey else { return }
			guard configSignature() == lastConfigSignature, pendingSelection == nil else {
				load(into: webView)   // needs a full load after all
				return
			}
			lastKey = key
			currentSource = text
			let fragment = MarkdownHTMLRenderer.renderBodyFragment(
				markdown: text, theme: parent.theme, fontSize: parent.fontSize,
				includeSourceOffsets: parent.isEditable,
				interactiveCheckboxes: parent.onCheckboxToggle != nil)
			guard let encoded = try? JSONEncoder().encode(fragment),
				  let json = String(data: encoded, encoding: .utf8) else {
				loadHTML(for: text, into: webView)
				return
			}
			log("body swap: textLen=\((text as NSString).length)")
			webView.evaluateJavaScript("window.__mdSwapContent && window.__mdSwapContent(\(json));", completionHandler: nil)
		}

		private func loadHTML(for text: String, into webView: WKWebView) {
			let html = MarkdownHTMLRenderer.renderDocument(
				markdown: text, theme: parent.theme, fontSize: parent.fontSize,
				includeSourceOffsets: parent.isEditable,
				interactiveCheckboxes: parent.onCheckboxToggle != nil,
				// Render mermaid as diagrams when the host opted in and we're not
				// editing (editing keeps the raw, editable source).
				embedMermaidEngine: parent.renderMermaid && !parent.isEditable)
			// Load under the custom resource scheme (when we have a document
			// folder) so relative <img> paths resolve to the scheme handler,
			// which can actually read local files — WKWebView won't load
			// file:// subresources of an loadHTMLString page.
			webView.loadHTMLString(html, baseURL: resourceBaseURL(for: parent.baseURL) ?? parent.baseURL)
		}

		/// A `markerlocalres://res/<folder-path>/` base URL so relative image
		/// paths resolve to the scheme handler. Nil when there's no file folder.
		private func resourceBaseURL(for fileURL: URL?) -> URL? {
			guard let folder = fileURL, folder.isFileURL else { return nil }
			var components = URLComponents()
			components.scheme = MarkdownWebView.resourceScheme
			components.host = "res"
			components.path = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
			return components.url
		}

		// MARK: Navigation

		public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
			if parent.onCheckboxToggle != nil {
				webView.evaluateJavaScript(Self.checkboxScript, completionHandler: nil)
			}
			// Always install scroll reporting / control, even for a read-only
			// preview, so a host can sync its scroll position to this view.
			webView.evaluateJavaScript(Self.scrollSyncScript, completionHandler: nil)
			if parent.isEditable {
				webView.evaluateJavaScript(Self.editorScript, completionHandler: nil)
			}
			// Restore position after a (re)load: a pending caret from a structural
			// edit wins; then a one-time initial fraction; then the last offset.
			if let selection = pendingSelection {
				pendingSelection = nil
				log("didFinish: restoring selection \(selection) (scrollY \(lastScrollY))")
				// Put the view back where the user was FIRST — the reload
				// starts at the top, and placing the caret from there parked
				// it at the bottom edge of the viewport. With the position
				// restored, the caret's own scrollIntoView(nearest) is a
				// no-op unless the caret would be off-screen (e.g. Return on
				// the last visible line), which nudges minimally.
				webView.evaluateJavaScript("window.__mdRestoreScrollThenCaret && window.__mdRestoreScrollThenCaret(\(lastScrollY), \(selection.location), \(selection.length));", completionHandler: nil)
			} else if !didApplyInitialScroll, let initial = parent.initialScrollFraction {
				didApplyInitialScroll = true
				log("didFinish: initial scroll fraction \(initial)")
				webView.evaluateJavaScript("window.__mdScrollToFraction && window.__mdScrollToFraction(\(initial));", completionHandler: nil)
			} else if lastScrollY > 0 {
				log("didFinish: restoring scrollY \(lastScrollY)")
				webView.evaluateJavaScript("window.__mdRestoreScrollThenCaret && window.__mdRestoreScrollThenCaret(\(lastScrollY), null, 0);", completionHandler: nil)
			}
		}

		/// Pick up a token-gated caret-restore request (undo/redo) and arm it as
		/// the pending caret. The accompanying `parent.text` change forces a
		/// reload, after which `webView(_:didFinish:)` re-stamps `data-s` and
		/// places the caret via `__mdPlaceCaret`. Clear `selfEditedText` so the
		/// reload is never skipped — even when the restored text happens to equal
		/// our last in-place edit.
		func applyCaretTarget() {
			guard let target = parent.caretTarget, target.token != lastCaretToken else { return }
			lastCaretToken = target.token
			// Only the editor the user is actually in restores its caret. In a
			// split, the other (preview) pane just re-renders — arming a caret here
			// would steal first responder from the focused pane and end editing.
			guard isFirstResponder else { return }
			pendingSelection = NSRange(location: target.offset, length: 0)
			selfEditedText = nil
		}

		/// True when this web view (or a descendant, e.g. the WKContentView) holds
		/// the window's first responder — i.e. it's the editor the user is in.
		private var isFirstResponder: Bool {
			guard let webView, let responder = webView.window?.firstResponder as? NSView else { return false }
			return responder === webView || responder.isDescendant(of: webView)
		}

		private var lastMirroredSelection: NSRange?

		/// Show (or clear) the other pane's selection as a highlight overlay.
		func applyMirroredSelection(to webView: WKWebView) {
			guard lastMirroredSelection != parent.mirroredSelection else { return }
			log("apply mirror \(String(describing: parent.mirroredSelection)) (was \(String(describing: lastMirroredSelection)))")
			lastMirroredSelection = parent.mirroredSelection
			if let range = parent.mirroredSelection, range.length > 0 {
				webView.evaluateJavaScript("window.__mdMirrorSelection && window.__mdMirrorSelection(\(range.location), \(range.length));", completionHandler: nil)
			} else {
				webView.evaluateJavaScript("window.__mdMirrorSelection && window.__mdMirrorSelection(null, 0);", completionHandler: nil)
			}
		}

		/// Apply token-gated scroll controls (target/delta) from the host.
		func applyScrollControls(to webView: WKWebView) {
			if let target = parent.scrollTarget, target.token != lastScrollTargetToken {
				lastScrollTargetToken = target.token
				log("scroll control: toFraction \(target.topFraction) token \(target.token)")
				webView.evaluateJavaScript("window.__mdScrollToFraction && window.__mdScrollToFraction(\(target.topFraction));", completionHandler: nil)
			}
			if let delta = parent.scrollDelta, delta.token != lastScrollDeltaToken {
				lastScrollDeltaToken = delta.token
				log("scroll control: byPixels \(delta.deltaY) token \(delta.token)")
				webView.evaluateJavaScript("window.__mdScrollByPixels && window.__mdScrollByPixels(\(delta.deltaY));", completionHandler: nil)
			}
			if let target = parent.sourceScrollTarget, target.token != lastSourceScrollToken {
				lastSourceScrollToken = target.token
				log("scroll control: toSourceOffset \(target.offset) token \(target.token)")
				webView.evaluateJavaScript("window.__mdScrollToSourceOffset && window.__mdScrollToSourceOffset(\(target.offset));", completionHandler: nil)
			}
		}

		public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
			guard navigationAction.navigationType == .linkActivated,
				  let url = navigationAction.request.url else {
				decisionHandler(.allow)
				return
			}
			if isInPageAnchor(url, base: webView.url) {
				decisionHandler(.allow)
				return
			}
			decisionHandler(.cancel)
			open(url)
		}

		private func isInPageAnchor(_ url: URL, base: URL?) -> Bool {
			guard url.fragment != nil else { return false }
			guard let base else { return url.scheme == "about" }
			return url.scheme == base.scheme && url.path == base.path
		}

		private func open(_ url: URL) {
			// Links resolve against the custom resource-scheme base; map them back
			// to real file URLs before opening.
			let resolved = url.scheme == MarkdownWebView.resourceScheme ? URL(fileURLWithPath: url.path) : url
			if resolved.isFileURL, Self.markdownExtensions.contains(resolved.pathExtension.lowercased()) {
				NSDocumentController.shared.openDocument(withContentsOf: resolved, display: true) { document, _, _ in
					if document == nil { NSWorkspace.shared.open(resolved) }
				}
			} else {
				NSWorkspace.shared.open(resolved)
			}
		}

		private static let markdownExtensions: Set<String> = MarkdownLinkExtensions.all

		/// The scheme handler couldn't read a local file (sandbox). Surface it so
		/// the host can offer a folder-access grant.
		func reportResourceAccessDenied() {
			parent.onResourceAccessDenied?()
		}

		// MARK: Edit bridge

		public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
			guard message.name == "mdedit", let body = message.body as? [String: Any] else { return }
			// Scroll position report — remembered so reloads don't jump to top, and
			// forwarded to the host (as top/visible/content fractions) for sync.
			if body["type"] as? String == "scroll" {
				if let y = body["y"] as? Double { lastScrollY = y }
				if let top = body["top"] as? Double,
				   let visible = body["visible"] as? Double,
				   let content = body["content"] as? Double {
					parent.onScrollFractionChanged?(CGFloat(top), CGFloat(visible), CGFloat(content))
				}
				return
			}
			if body["type"] as? String == "error" {
				log("JS error: \(body["message"] as? String ?? "?")")
				return
			}
			if body["type"] as? String == "ready" {
				log("editor ready (bridge=\(body["bridge"] as? Bool ?? false))")
				return
			}
			if body["type"] as? String == "selection" {
				log("selection message start=\(body["start"] ?? "nil") length=\(body["length"] ?? "nil") handler=\(parent.onSelectionChanged != nil)")
				if let start = body["start"] as? Int, let length = body["length"] as? Int, length > 0 {
					parent.onSelectionChanged?(NSRange(location: start, length: length))
				} else {
					parent.onSelectionChanged?(nil)
				}
				return
			}
			if body["type"] as? String == "openLink" {
				if let href = body["href"] as? String, let url = URL(string: href) {
					open(url)
				}
				return
			}
			// Task-list checkbox click (QuickLook): map index → source and write.
			if body["type"] as? String == "checkbox" {
				if let index = body["index"] as? Int, let checked = body["checked"] as? Bool {
					parent.onCheckboxToggle?(index, checked)
				}
				return
			}
			// The DOM took an edit the script couldn't map (e.g. an IME
			// composition outside a stamped run); re-render so it can't drift.
			if body["type"] as? String == "desync" {
				log("desync reported by page")
				resync(caretAt: nil)
				return
			}
			log("message \(body)")
			guard let edit = MarkdownEditSplicer.Edit(body: body) else { return }
			let source = currentSource ?? parent.text
			switch MarkdownEditSplicer.apply(edit, to: source) {
			case .applied(let newSource, let selection):
				currentSource = newSource
				log("applied start=\(edit.start) end=\(edit.end) newLen=\(newSource.count)")
				if edit.caret != nil, let selection {
					// Structural edit: re-render (re-stamps data-s) and restore
					// the selection (style toggles keep their selection alive;
					// other edits collapse to a caret). Don't suppress the reload.
					pendingSelection = selection
					parent.onSourceEdit?(newSource)
				} else {
					// In-place edit: the DOM already shows it (and the page shifted
					// its own data-s stamps), so skip the reload.
					selfEditedText = newSource
					lastKey = renderKey(text: newSource)
					parent.onSourceEdit?(newSource)
				}
			case .rejected(let reason):
				// The offsets and the source disagree — and for the fast-path
				// edits the browser has already mutated the DOM, so leaving the
				// page alone would let the view drift away from the source.
				// Re-render from the source we hold and put the caret back near
				// the edit; the user loses one keystroke, never file content.
				log("rejected: \(reason)")
				resync(caretAt: min(max(0, edit.start), (source as NSString).length))
			}
		}

		/// Reload the page from `currentSource` — not `parent.text`, which lags
		/// an in-flight SwiftUI round-trip — re-stamping every run.
		private func resync(caretAt caret: Int?) {
			guard let webView else { return }
			let source = currentSource ?? parent.text
			pendingSwap?.cancel()
			pendingSwap = nil
			selfEditedText = nil
			pendingSelection = caret.map { NSRange(location: $0, length: 0) }
			lastKey = renderKey(text: source)
			lastConfigSignature = configSignature()
			loadHTML(for: source, into: webView)
		}

		private func log(_ message: String) {
			guard Self.debugEditing else { return }
			print("[MarkdownWebView] \(message)")
			NSLog("[MarkdownWebView] %@", message)
		}
	}
}

/// Serves local files referenced by the rendered page (images, etc.) under the
/// custom resource scheme. The request URL's path is the real filesystem path,
/// so we read the bytes directly — the way to show local images in a
/// `loadHTMLString` page, which WKWebView won't let load `file://` subresources.
private final class LocalResourceSchemeHandler: NSObject, WKURLSchemeHandler {
	weak var coordinator: MarkdownWebView.Coordinator?

	init(coordinator: MarkdownWebView.Coordinator?) {
		self.coordinator = coordinator
		super.init()
	}

	func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
		guard let url = task.request.url else {
			task.didFailWithError(URLError(.badURL)); return
		}
		let fileURL = URL(fileURLWithPath: url.path)
		guard let data = try? Data(contentsOf: fileURL) else {
			task.didFailWithError(URLError(.noPermissionsToReadFile))
			let coordinator = coordinator
			Task { @MainActor in coordinator?.reportResourceAccessDenied() }
			return
		}
		let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
		let response = URLResponse(url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: nil)
		task.didReceive(response)
		task.didReceive(data)
		task.didFinish()
	}

	func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// Breaks the WKUserContentController → handler retain cycle (the controller
/// holds the handler strongly, and the web view holds the controller).
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
	weak var delegate: WKScriptMessageHandler?
	init(_ delegate: WKScriptMessageHandler) { self.delegate = delegate }
	func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
		delegate?.userContentController(controller, didReceive: message)
	}
}

extension MarkdownWebView.Coordinator {
	/// Injected when a checkbox-toggle callback is wired (QuickLook). Reports a
	/// task-list checkbox click — by its `data-cb` document-wide index — so the
	/// host can rewrite the source. Works whether or not the page is editable.
	static let checkboxScript = """
	(function () {
	  document.body.addEventListener('change', function (e) {
	    var t = e.target;
	    if (t && t.tagName === 'INPUT' && t.type === 'checkbox' && t.hasAttribute('data-cb')) {
	      var idx = parseInt(t.getAttribute('data-cb'), 10);
	      if (!isNaN(idx)) {
	        window.webkit.messageHandlers.mdedit.postMessage({ type: 'checkbox', index: idx, checked: t.checked });
	      }
	    }
	  });
	})();
	"""

	/// Injected after each editable load. Maps contentEditable edits to source
	/// splices via `data-s` offsets, vetoing anything it can't map.
	static var editorScript: String {
		"""
	(function () {
	  // Surface any uncaught JS error (incl. in event listeners) to Swift so a
	  // silent failure in the bridge is diagnosable.
	  window.onerror = function (msg, src, line, col) {
	    try { window.webkit.messageHandlers.mdedit.postMessage({ type: 'error', message: String(msg) + ' @' + line + ':' + col }); } catch (e) {}
	  };
	  // Confirm the script ran AND the message bridge is reachable.
	  try {
	    window.webkit.messageHandlers.mdedit.postMessage({ type: 'ready', bridge: !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mdedit) });
	  } catch (e) {}
	  document.body.contentEditable = 'true';
	  document.body.style.outline = 'none';
	  // Blocks we can't map edits inside become read-only islands, so the caret
	  // can't land somewhere a keystroke would be silently vetoed.
	  document.querySelectorAll('pre, table, .alert, details, .frontmatter, img, hr').forEach(function (el) {
	    el.contentEditable = 'false';
	  });
	  // Edits awaiting their `input` event, oldest first. A QUEUE, not a slot:
	  // WebKit batches multiple editing commands into one turn — typing a
	  // quote both inserts it AND retroactively curls the previous quote via
	  // insertReplacementText — and a single slot dropped all but the last
	  // edit, desyncing the source and getting the batch rejected.
	  var pendingEdits = [];
	  // A structural edit or desync was posted; swallow input until the host's
	  // re-render (which reinjects this script) so nothing maps from a source
	  // that's about to change shape.
	  var frozen = false;
	  // State captured at compositionstart, reconciled at compositionend.
	  var composing = null;
	  installLinkOpenButtons();

	  function textLength(n) {
	    if (n.nodeType === 3) return n.nodeValue.length;
	    var t = 0; for (var i = 0; i < n.childNodes.length; i++) t += textLength(n.childNodes[i]);
	    return t;
	  }
	  // Characters of text inside `root` that precede position (node, offset).
	  function textOffsetWithin(root, node, offset) {
	    var count = 0, found = false;
	    function walk(n) {
	      if (found) return;
	      if (n === node) {
	        if (n.nodeType === 3) { count += offset; }
	        else { for (var i = 0; i < offset && i < n.childNodes.length; i++) count += textLength(n.childNodes[i]); }
	        found = true; return;
	      }
	      if (n.nodeType === 3) { count += n.nodeValue.length; return; }
	      for (var i = 0; i < n.childNodes.length; i++) { walk(n.childNodes[i]); if (found) return; }
	    }
	    walk(root);
	    return found ? count : null;
	  }
	  // The [data-s] run element owning a DOM position, or null.
	  function spanOf(node, offset) {
	    var el = node.nodeType === 3 ? node.parentNode : node;
	    if (node.nodeType !== 3 && node.childNodes.length) {
	      var child = node.childNodes[Math.min(offset || 0, node.childNodes.length - 1)];
	      if (child) el = child.nodeType === 3 ? child.parentNode : child;
	    }
	    return el && el.closest ? el.closest('[data-s]') : null;
	  }
	  function firstTextIn(n) {
	    if (n.nodeType === 3) return n;
	    for (var i = 0; i < n.childNodes.length; i++) { var t = firstTextIn(n.childNodes[i]); if (t) return t; }
	    return null;
	  }
	  function lastTextIn(n) {
	    if (n.nodeType === 3) return n;
	    for (var i = n.childNodes.length - 1; i >= 0; i--) { var t = lastTextIn(n.childNodes[i]); if (t) return t; }
	    return null;
	  }
	  // Element-level positions (block-boundary target ranges: paragraph
	  // merges, whole-block selections) resolve to the nearest text-node
	  // position so they map to the source like any other. A child with no
	  // text inside (the <br>-only caret placeholder Enter creates) anchors
	  // on the child element itself — the offset arithmetic handles element
	  // positions inside a stamped run.
	  function normalizePosition(node, offset) {
	    if (node.nodeType === 3 || !node.childNodes.length) return { node: node, offset: offset };
	    var t;
	    if (offset > 0) {
	      var last = node.childNodes[Math.min(offset, node.childNodes.length) - 1];
	      t = lastTextIn(last);
	      if (t) return { node: t, offset: t.nodeValue.length };
	      return { node: last, offset: last.childNodes ? last.childNodes.length : 0 };
	    }
	    var first = node.childNodes[Math.min(offset, node.childNodes.length - 1)];
	    t = firstTextIn(first);
	    if (t) return { node: t, offset: 0 };
	    return { node: first, offset: 0 };
	  }
	  // Source offset for a DOM position, or null if it isn't inside a run.
	  function sourceOffsetOf(node, offset) {
	    var span = spanOf(node, offset);
	    if (!span) return null;
	    var base = parseInt(span.getAttribute('data-s'), 10);
	    var chars = textOffsetWithin(span, node, offset);
	    if (chars == null) return null;
	    return base + chars;
	  }
	  // DOM text just before/after a position within its run. Swift verifies it
	  // against the source before splicing, so a stale or drifted offset gets
	  // rejected (and resynced) instead of splicing into the wrong place.
	  // Trimmed so a split surrogate pair can't garble the message bridge.
	  function contextBefore(node, offset) {
	    var span = spanOf(node, offset);
	    if (!span) return '';
	    var o = textOffsetWithin(span, node, offset);
	    if (o == null) return '';
	    var t = span.textContent;
	    var s = t.substring(Math.max(0, o - 12), o);
	    if (s.length && s.charCodeAt(0) >= 0xDC00 && s.charCodeAt(0) <= 0xDFFF) s = s.substring(1);
	    return plain(s);
	  }
	  function contextAfter(node, offset) {
	    var span = spanOf(node, offset);
	    if (!span) return '';
	    var o = textOffsetWithin(span, node, offset);
	    if (o == null) return '';
	    var t = span.textContent;
	    var s = t.substring(o, Math.min(t.length, o + 12));
	    var last = s.length ? s.charCodeAt(s.length - 1) : 0;
	    if (last >= 0xD800 && last <= 0xDBFF) s = s.substring(0, s.length - 1);
	    return plain(s);
	  }
	  // After an in-place edit, every run at or past the edit moved by the
	  // edit's length delta; keep the data-s stamps in step so the next edit
	  // maps from fresh offsets instead of pre-edit geometry.
	  function shiftStamps(start, delta, editedSpan) {
	    if (!delta) return;
	    document.querySelectorAll('[data-s]').forEach(function (el) {
	      if (el === editedSpan) return;
	      var base = parseInt(el.getAttribute('data-s'), 10);
	      var follows = base > start || (base === start && editedSpan &&
	        (editedSpan.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_FOLLOWING));
	      if (follows) el.setAttribute('data-s', String(base + delta));
	    });
	  }
	  // The host swapped in freshly rendered content (see __mdSwapContent):
	  // drop any in-flight edit state — its offsets described the old DOM —
	  // and re-run the per-content setup. The body's own listeners survive.
	  window.__mdAfterSwap = function () {
	    pendingEdits = [];
	    frozen = false;
	    composing = null;
	    document.querySelectorAll('pre, table, .alert, details, .frontmatter, img, hr').forEach(function (el) {
	      el.contentEditable = 'false';
	    });
	    installLinkOpenButtons();
	  };
	  function placeCaretIn(node, offset, anchor) {
	    // Re-focus the editable body: a reload (e.g. after undo) clears DOM
	    // focus, so without this the caret wouldn't blink and typing wouldn't
	    // resume. Only reached when the host armed a caret for the focused
	    // web view, so this never steals focus from another split pane.
	    // preventScroll: focusing the body otherwise scrolls to the top,
	    // wiping the scroll position that was just restored.
	    document.body.focus({ preventScroll: true });
	    var sel = window.getSelection(), r = document.createRange();
	    r.setStart(node, offset); r.collapse(true);
	    sel.removeAllRanges(); sel.addRange(r);
	    anchor.scrollIntoView({ block: 'nearest' });
	  }
	  function blockOf(el) {
	    return el.closest('p, li, h1, h2, h3, h4, h5, h6, blockquote, td, th') || el;
	  }
	  // DOM position for a source offset, or null when no run covers it.
	  function spotFor(offset) {
	    var spans = document.querySelectorAll('[data-s]');
	    for (var i = 0; i < spans.length; i++) {
	      var base = parseInt(spans[i].getAttribute('data-s'), 10);
	      var len = textLength(spans[i]);
	      if (offset >= base && offset <= base + len) {
	        var spot = locate(spans[i], offset - base);
	        if (spot) { spot.span = spans[i]; return spot; }
	      }
	    }
	    return null;
	  }
	  // Show the other pane's selection as a highlight overlay, without
	  // touching this page's real selection. The ::highlight(md-mirror) rule
	  // ships in the theme stylesheet (MarkdownHTMLRenderer.css(for:)), so the
	  // wash color follows the theme.
	  // WebKit does not repaint painted highlight regions when the
	  // CSS.highlights registry mutates — a deleted mirror stays on screen
	  // until something else invalidates it. Toggling a compositing layer on
	  // the body forces the full repaint that flushes it.
	  function repaintMirror() {
	    var b = document.body;
	    if (!b) { return; }
	    b.style.transform = 'translateZ(0)';
	    void b.offsetWidth;
	    b.style.transform = '';
	  }
	  window.__mdMirrorSelection = function (offset, length) {
	    if (!window.Highlight || !CSS.highlights) { return; }
	    if (offset == null || !length) { CSS.highlights.delete('md-mirror'); repaintMirror(); return; }
	    var start = spotFor(offset);
	    var end = spotFor(offset + length);
	    if (!start || !end) { CSS.highlights.delete('md-mirror'); repaintMirror(); return; }
	    // A mirror means the OTHER pane is active — this page's leftover real
	    // selection (e.g. restored by a style toggle) would read as a second
	    // selection next to the mirror, so drop it while we're not focused.
	    if (!document.hasFocus()) {
	      var stale = window.getSelection();
	      if (stale && !stale.isCollapsed) { stale.removeAllRanges(); }
	    }
	    var r = new Range();
	    r.setStart(start.node, start.offset);
	    r.setEnd(end.node, end.offset);
	    CSS.highlights.set('md-mirror', new Highlight(r));
	    repaintMirror();
	  };
	  // Report selection changes as source offsets for cross-pane mirroring;
	  // only while this page is focused, so the mirror always reflects the
	  // pane the user is actually working in.
	  function reportSelection() {
	    if (!document.hasFocus()) { return; }
	    var sel = window.getSelection();
	    if (!sel || !sel.rangeCount || sel.isCollapsed) { post({ type: 'selection' }); return; }
	    var r = sel.getRangeAt(0);
	    var startPos = normalizePosition(r.startContainer, r.startOffset);
	    var endPos = normalizePosition(r.endContainer, r.endOffset);
	    var start = sourceOffsetOf(startPos.node, startPos.offset);
	    var end = sourceOffsetOf(endPos.node, endPos.offset);
	    if (start == null || end == null || end <= start) { post({ type: 'selection' }); return; }
	    post({ type: 'selection', start: start, length: end - start });
	  }
	  var selectionReportTimer = null;
	  document.addEventListener('selectionchange', function () {
	    if (selectionReportTimer) { clearTimeout(selectionReportTimer); }
	    selectionReportTimer = setTimeout(function () {
	      selectionReportTimer = null;
	      reportSelection();
	    }, 120);
	  });
	  // Becoming the active pane: this pane's own mirror is stale. Drop the
	  // highlight synchronously — the host round trip (post → state →
	  // updateNSView → evaluateJavaScript) is visibly slow — then report so
	  // the host state follows. mousedown fires before focus arrives, so the
	  // highlight is gone before the click even lands.
	  function clearOwnMirror() {
	    if (window.CSS && CSS.highlights && CSS.highlights.has('md-mirror')) {
	      CSS.highlights.delete('md-mirror');
	      repaintMirror();
	    }
	  }
	  document.addEventListener('mousedown', clearOwnMirror, true);
	  window.addEventListener('focus', function () {
	    clearOwnMirror();
	    // Deferred: during the focus event document.hasFocus() can still be
	    // false, which would swallow the report inside reportSelection().
	    setTimeout(reportSelection, 0);
	  });
	  // Restore the caret — or, with a length, the full selection (style
	  // toggles keep their selection alive) — after a structural re-render.
	  window.__mdPlaceCaret = function (offset, length) {
	    length = length || 0;
	    var start = spotFor(offset);
	    if (start && length) {
	      var end = spotFor(offset + length) || start;
	      document.body.focus({ preventScroll: true });
	      var sel = window.getSelection(), r = document.createRange();
	      r.setStart(start.node, start.offset);
	      r.setEnd(end.node, end.offset);
	      sel.removeAllRanges(); sel.addRange(r);
	      start.span.scrollIntoView({ block: 'nearest' });
	      return;
	    }
	    if (start) {
	      placeCaretIn(start.node, start.offset, start.span);
	      return;
	    }
	    if (length) { return; }   // a selection can't restore into a void
	    var spans = document.querySelectorAll('[data-s]');
	    var prev = null, next = null;
	    for (var i = 0; i < spans.length; i++) {
	      var base = parseInt(spans[i].getAttribute('data-s'), 10);
	      var len = textLength(spans[i]);
	      if (base + len < offset) { prev = spans[i]; }
	      if (base > offset && !next) { next = spans[i]; }
	    }
	    // No run covers the offset: the caret sits in markdown the renderer
	    // has no text for — the empty paragraph Enter just created. Without a
	    // home the caret was silently dropped and the fresh page sat at the
	    // top of the document. Give the offset a stamped, empty run so the
	    // caret lands there and the next keystroke maps to the right spot.
	    var holder = document.createElement('span');
	    holder.setAttribute('data-s', String(offset));
	    holder.appendChild(document.createElement('br'));
	    var prevBlock = prev ? blockOf(prev) : null;
	    var nextBlock = next ? blockOf(next) : null;
	    var target = null;
	    // Prefer an empty block the renderer DID emit between the neighbours
	    // (an empty list item renders as a bare <li>).
	    if (prevBlock && prevBlock.nextElementSibling && prevBlock.nextElementSibling !== nextBlock
	        && textLength(prevBlock.nextElementSibling) === 0
	        && !prevBlock.nextElementSibling.hasAttribute('data-s')) {
	      target = prevBlock.nextElementSibling;
	    } else {
	      target = document.createElement('p');
	      if (prevBlock && prevBlock.parentNode) { prevBlock.insertAdjacentElement('afterend', target); }
	      else if (nextBlock && nextBlock.parentNode) { nextBlock.insertAdjacentElement('beforebegin', target); }
	      else { document.body.appendChild(target); }
	    }
	    target.insertBefore(holder, target.firstChild);
	    placeCaretIn(holder, 0, holder);
	  };
	  // DOM position for the `target`-th character inside `root`.
	  function locate(root, target) {
	    var count = 0, found = null;
	    function walk(n) {
	      if (found) return;
	      if (n.nodeType === 3) {
	        if (target <= count + n.nodeValue.length) { found = { node: n, offset: target - count }; return; }
	        count += n.nodeValue.length;
	      } else { for (var i = 0; i < n.childNodes.length; i++) { walk(n.childNodes[i]); if (found) return; } }
	    }
	    walk(root);
	    return found;
	  }
	  // List-item continuation marker, or null when not in a list.
	  function listItemMarker(node) {
	    var el = node.nodeType === 3 ? node.parentNode : node;
	    var li = el && el.closest ? el.closest('li') : null;
	    if (!li) return null;
	    return li.parentElement && li.parentElement.tagName === 'OL' ? '\\n1. ' : '\\n- ';
	  }
	  function post(msg) { window.webkit.messageHandlers.mdedit.postMessage(msg); }
	  function installLinkOpenButtons() {
	    if (!document.getElementById('md-link-open-button-style')) {
	      var style = document.createElement('style');
	      style.id = 'md-link-open-button-style';
	      style.textContent = `
	        .md-link-open-button {
	          display: inline-flex;
	          width: 16px;
	          height: 16px;
	          margin: 0 0 0 3px;
	          padding: 0;
	          border: 0;
	          border-radius: 50%;
	          vertical-align: -2px;
	          align-items: center;
	          justify-content: center;
	          background-color: transparent;
	          color: currentColor;
	          cursor: pointer;
	          -webkit-user-select: none;
	          user-select: none;
	          opacity: 0.82;
	          \(Self.linkOpenButtonIconCSS)
	        }
	        .md-link-open-button:hover {
	          opacity: 1;
	          background-color: rgba(127, 127, 127, 0.12);
	        }
	        .md-link-open-button:focus-visible {
	          outline: 2px solid currentColor;
	          outline-offset: 1px;
	        }
	        .md-link-open-button:not(.has-symbol-icon)::before {
	          content: "→";
	          font-size: 13px;
	          line-height: 1;
	        }
	        .md-link-open-button.has-symbol-icon::before {
	          content: "";
	          width: 14px;
	          height: 14px;
	          background-color: currentColor;
	          -webkit-mask-image: url('\(Self.linkOpenButtonIconDataURI ?? "")');
	          -webkit-mask-position: center;
	          -webkit-mask-repeat: no-repeat;
	          -webkit-mask-size: 14px 14px;
	          mask-image: url('\(Self.linkOpenButtonIconDataURI ?? "")');
	          mask-position: center;
	          mask-repeat: no-repeat;
	          mask-size: 14px 14px;
	        }
	      `;
	      document.head.appendChild(style);
	    }

	    document.querySelectorAll('a[href]').forEach(function (link) {
	      if (link.dataset.mdOpenDecorated === '1') { return; }
	      if (link.closest('.md-link-open-button')) { return; }
	      link.dataset.mdOpenDecorated = '1';
	      var displayHref = link.href;
	      if (link.href.indexOf('markerlocalres://') === 0) {
	        displayHref = link.getAttribute('href') || link.href;
	      }
	      link.title = displayHref;

	      var button = document.createElement('button');
	      button.type = 'button';
	      button.className = 'md-link-open-button\(Self.linkOpenButtonHasIcon ? " has-symbol-icon" : "")';
	      button.contentEditable = 'false';
	      button.tabIndex = -1;
	      button.title = displayHref;
	      button.style.color = window.getComputedStyle(link).color;
	      button.setAttribute('aria-label', 'Open link');
	      button.setAttribute('data-href', link.href);
	      button.addEventListener('mousedown', function (e) {
	        e.preventDefault();
	        e.stopPropagation();
	      });
	      button.addEventListener('click', function (e) {
	        e.preventDefault();
	        e.stopPropagation();
	        post({ type: 'openLink', href: button.getAttribute('data-href') });
	      });

	      var target = link;
	      var sourceRun = link.closest('[data-s]');
	      if (sourceRun && sourceRun.parentNode) { target = sourceRun; }
	      target.insertAdjacentElement('afterend', button);
	    });
	  }
	  // WebKit freely swaps spaces and non-breaking spaces inside
	  // contentEditable text to keep visual runs from collapsing — the DOM
	  // drifts from the source by U+00A0s on almost every insertion. The
	  // swap is 1:1 in UTF-16 so offsets are unaffected; normalize every
	  // string that crosses the bridge so it can't fail verification.
	  function plain(s) { return s ? s.replace(/\\u00A0/g, ' ') : s; }
	  // getTargetRanges() yields StaticRanges, whose toString() is useless
	  // ("[object StaticRange]"). Build a live Range to read the replaced text.
	  function rangeText(r) {
	    if (r.collapsed) return '';
	    try {
	      var live = document.createRange();
	      live.setStart(r.startContainer, r.startOffset);
	      live.setEnd(r.endContainer, r.endOffset);
	      return live.toString();
	    } catch (e) { return ''; }
	  }

	  document.body.addEventListener('beforeinput', function (e) {
	    // Undo/redo are owned by the host (a unified, source-level stack reached
	    // via the app's Undo menu command). Block WebKit's own DOM-level history
	    // so it can't desync the source or move the caret. Checked first, before
	    // the range lookup, because a history beforeinput may carry no range.
	    if (e.inputType === 'historyUndo' || e.inputType === 'historyRedo') { e.preventDefault(); return; }
	    // While a composition is live (IME, dead keys, inline predictive
	    // text), marked text sits in the DOM that the source doesn't have, so
	    // no event can be mapped through offsets — not even plain insertText,
	    // whose target range would be tainted by the grey prediction text.
	    // Everything composition-adjacent is reconciled at compositionend by
	    // diffing the whole run instead.
	    if (composing || e.isComposing || e.inputType === 'insertCompositionText' || e.inputType === 'deleteCompositionText') return;
	    if (frozen) { e.preventDefault(); return; }
	    var ranges = e.getTargetRanges();
	    var range = ranges && ranges.length ? ranges[0] : null;
	    if (!range && (e.inputType === 'formatBold' || e.inputType === 'formatItalic')) {
	      // Formatting commands report no target ranges; they act on the
	      // selection, so read it directly.
	      var formatSel = window.getSelection();
	      if (formatSel && formatSel.rangeCount) { range = formatSel.getRangeAt(0); }
	    }
	    if (!range) { e.preventDefault(); return; }
	    var startPos = normalizePosition(range.startContainer, range.startOffset);
	    var endPos = normalizePosition(range.endContainer, range.endOffset);
	    var start = sourceOffsetOf(startPos.node, startPos.offset);
	    var end = sourceOffsetOf(endPos.node, endPos.offset);
	    if (start == null || end == null || end < start) { e.preventDefault(); return; }
	    var type = e.inputType, expected = plain(rangeText(range));
	    var startSpan = spanOf(startPos.node, startPos.offset);
	    var crossRun = startSpan !== spanOf(endPos.node, endPos.offset);
	    // A real selection means the user chose the range — hidden syntax
	    // inside it may go. A collapsed caret (block merge) may only remove
	    // whitespace; the Swift side enforces the distinction.
	    var selected = !window.getSelection().isCollapsed;
	    var before = contextBefore(startPos.node, startPos.offset);
	    var after = contextAfter(endPos.node, endPos.offset);

	    // Fast path: in-place text edits within a single run. Let the browser
	    // mutate the DOM and mirror the change to the source (no reload). Edits
	    // that span runs touch markdown syntax the DOM doesn't show, so they
	    // take the structural route instead: splice the source (context-
	    // verified) and re-render.
	    if (type === 'insertText' || type === 'insertReplacementText') {
	      var data = e.data;
	      // Autocorrect/spelling replacements deliver their text via dataTransfer.
	      if (data == null && e.dataTransfer) data = e.dataTransfer.getData('text/plain');
	      if (data == null) { e.preventDefault(); return; }
	      data = plain(data);
	      if (crossRun) {
	        e.preventDefault();
	        frozen = true;
	        post({ start: start, end: end, text: data, expected: expected, crossRun: true, selected: selected, before: before, after: after, caret: start + data.length });
	        return;
	      }
	      pendingEdits.push({ msg: { start: start, end: end, text: data, expected: expected, before: before, after: after },
	                          shift: { start: start, delta: data.length - (end - start), span: startSpan } });
	      return;
	    }
	    if (type === 'deleteContentBackward' || type === 'deleteContentForward' ||
	        type === 'deleteWordBackward' || type === 'deleteWordForward' || type === 'deleteByCut') {
	      if (crossRun) {
	        e.preventDefault();
	        frozen = true;
	        post({ start: start, end: end, text: '', expected: expected, crossRun: true, selected: selected, before: before, after: after, caret: start });
	        return;
	      }
	      pendingEdits.push({ msg: { start: start, end: end, text: '', expected: expected, before: before, after: after },
	                          shift: { start: start, delta: -(end - start), span: startSpan } });
	      return;
	    }

	    // Structural edits: splice the source and re-render (re-stamps data-s),
	    // restoring the caret. Block the browser's own DOM mutation.
	    if (type === 'insertParagraph') {
	      e.preventDefault();
	      var marker = listItemMarker(range.startContainer) || '\\n\\n';
	      frozen = true;
	      post({ start: start, end: end, text: marker, expected: expected, crossRun: crossRun, before: before, after: after, caret: start + marker.length });
	      return;
	    }
	    if (type === 'formatBold' || type === 'formatItalic') {
	      e.preventDefault();
	      if (start === end) return;  // need a selection to wrap
	      var m = type === 'formatBold' ? '**' : '*';
	      frozen = true;
	      post({ op: 'wrap', marker: m, start: start, end: end, expected: expected, crossRun: crossRun, before: before, after: after, caret: end + 2 * m.length });
	      return;
	    }

	    e.preventDefault();  // line breaks, paste, etc. — not yet mapped
	  });
	  document.body.addEventListener('input', function () {
	    while (pendingEdits.length) {
	      var queued = pendingEdits.shift();
	      post(queued.msg);
	      if (queued.shift) { shiftStamps(queued.shift.start, queued.shift.delta, queued.shift.span); }
	    }
	  });
	  // Composition (IME, dead keys, macOS inline predictive text) can't be
	  // vetoed or mapped per keystroke: marked text lives in the DOM without
	  // existing in the source, and plain inserts interleave with it. Instead,
	  // snapshot the run when composition starts and reconcile the whole run —
	  // one verified replacement — when it ends. That covers whatever the
	  // composition did: committed predictions, dead-key accents, CJK input,
	  // and ordinary characters typed while a prediction was showing.
	  document.body.addEventListener('compositionstart', function () {
	    var sel = window.getSelection();
	    var r = sel && sel.rangeCount ? sel.getRangeAt(0) : null;
	    var startPos = r ? normalizePosition(r.startContainer, r.startOffset) : null;
	    var endPos = r ? normalizePosition(r.endContainer, r.endOffset) : null;
	    var span = startPos ? spanOf(startPos.node, startPos.offset) : null;
	    var endSpan = endPos ? spanOf(endPos.node, endPos.offset) : null;
	    if (!r || frozen || !span || span !== endSpan) {
	      composing = { desync: true };
	      return;
	    }
	    composing = {
	      span: span,
	      base: parseInt(span.getAttribute('data-s'), 10),
	      beforeText: plain(span.textContent)
	    };
	  });
	  document.body.addEventListener('compositionend', function () {
	    var c = composing; composing = null;
	    if (!c) return;
	    if (c.desync || !c.span.isConnected) {
	      // The DOM may hold composed text we couldn't map; re-render.
	      frozen = true;
	      post({ type: 'desync' });
	      return;
	    }
	    var after = plain(c.span.textContent);
	    if (after === c.beforeText) return;  // canceled, nothing changed
	    post({ start: c.base, end: c.base + c.beforeText.length, text: after, expected: c.beforeText, before: '', after: '' });
	    shiftStamps(c.base, after.length - c.beforeText.length, c.span);
	  });
	  // Report scroll so a reload can restore the reader's place.
	  window.addEventListener('scroll', function () {
	    window.webkit.messageHandlers.mdedit.postMessage({ type: 'scroll', y: window.scrollY });
	  }, { passive: true });
	})();
	"""
	}

	private static var linkOpenButtonHasIcon: Bool {
		linkOpenButtonIconDataURI != nil
	}

	private static var linkOpenButtonIconCSS: String {
		""
	}

	private static let linkOpenButtonIconDataURI: String? = {
		guard let symbol = NSImage(systemSymbolName: "arrow.right.circle", accessibilityDescription: nil) else { return nil }
		let size = NSSize(width: 14, height: 14)
		let image = NSImage(size: size)
		image.lockFocus()
		NSColor.labelColor.set()
		symbol.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
		image.unlockFocus()
		guard let tiff = image.tiffRepresentation,
		      let rep = NSBitmapImageRep(data: tiff),
		      let png = rep.representation(using: .png, properties: [:]) else { return nil }
		return "data:image/png;base64,\(png.base64EncodedString())"
	}()

	/// Installed after every load (editable or not). Reports scroll position as
	/// top/visible/content fractions — matching MarkdownTextView's semantics so a
	/// host can sync the two — and exposes scroll-control hooks the coordinator
	/// calls. Idempotent so repeated injection is harmless.
	static let scrollSyncScript = """
	(function () {
	  if (window.__mdScrollSyncInstalled) { return; }
	  window.__mdScrollSyncInstalled = true;
	  function docHeight() {
	    return Math.max(document.documentElement.scrollHeight, document.body.scrollHeight, 1);
	  }
	  // While a host-driven scroll is in flight, its echo must not report as
	  // a user scroll — in a split view that echo claims scroll-sourcehood
	  // and yanks the pane the user is actually scrolling. The echo is
	  // consumed when the position settles at the target (or after a grace
	  // period, if the user interrupted the drive).
	  var driven = null;
	  function report() {
	    var h = docHeight();
	    var vis = window.innerHeight;
	    var y = window.scrollY || window.pageYOffset || 0;
	    if (driven) {
	      if (Math.abs(y - driven.y) < 3) {
	        // At the driven position: this and any repeat events are echoes.
	        // Stay armed — WebKit re-fires at a pinned position (e.g. clamped
	        // at the bottom), and one leaked echo re-claims scroll-sourcehood.
	        driven.settled = true;
	        return;
	      }
	      if (driven.settled || Date.now() > driven.until) { driven = null; }
	      else { return; }   // still converging on the target
	    }
	    // `top` is the fraction of the SCROLLABLE range (offset / (content −
	    // viewport)), matching MarkdownTextEditor's convention on both its
	    // report and apply sides — full-height fractions max out below 1.0
	    // and leave the synced pane short of the bottom.
	    var maxY = Math.max(h - vis, 0);
	    var top = maxY > 0 ? Math.max(0, Math.min(1, y / maxY)) : 0;
	    var visible = Math.max(0, Math.min(1, vis / h));
	    var content = vis > 0 ? Math.min(1, h / vis) : 1;
	    try {
	      window.webkit.messageHandlers.mdedit.postMessage({ type: 'scroll', y: y, top: top, visible: visible, content: content });
	    } catch (e) {}
	  }
	  var ticking = false;
	  window.addEventListener('scroll', function () {
	    if (ticking) { return; }
	    ticking = true;
	    window.requestAnimationFrame(function () { ticking = false; report(); });
	  }, { passive: true });
	  window.__mdScrollToFraction = function (f) {
	    var h = docHeight();
	    var vis = window.innerHeight;
	    var maxY = Math.max(h - vis, 0);
	    // Top-anchored fraction of the scrollable range — the same units
	    // report() emits, so a drive→echo round trip is the identity and the
	    // panes agree at both ends of the document.
	    var y = Math.max(0, Math.min(1, f)) * maxY;
	    driven = { y: y, until: Date.now() + 500 };
	    window.scrollTo(0, y);
	  };
	  window.__mdScrollByPixels = function (dy) {
	    var target = Math.max(0, (window.scrollY || 0) + dy);
	    driven = { y: target, until: Date.now() + 500 };
	    window.scrollBy(0, dy);
	  };
	  // Scroll the run rendering a source offset into view (outline
	  // navigation). Heading offsets point at their `#` markers, which no run
	  // covers, so target the first run ending at or after the offset.
	  window.__mdScrollToSourceOffset = function (offset) {
	    var spans = document.querySelectorAll('[data-s]');
	    var best = null;
	    for (var i = 0; i < spans.length; i++) {
	      var base = parseInt(spans[i].getAttribute('data-s'), 10);
	      if (base + spans[i].textContent.length >= offset) { best = spans[i]; break; }
	    }
	    if (!best && spans.length) { best = spans[spans.length - 1]; }
	    if (!best) { return; }
	    var maxY = Math.max(docHeight() - window.innerHeight, 0);
	    var y = Math.max(0, Math.min(maxY, best.getBoundingClientRect().top + window.scrollY - 12));
	    driven = { y: y, until: Date.now() + 500 };
	    window.scrollTo(0, y);
	  };
	  // Restore a scroll position on a freshly loaded page, then optionally
	  // place the caret. Straight scrollTo at didFinish clamps to zero — the
	  // content hasn't laid out yet — so retry until the page is tall enough
	  // (or a deadline passes), and only then let the caret nudge the view.
	  window.__mdRestoreScrollThenCaret = function (y, caret, length) {
	    var deadline = Date.now() + 1000;
	    function attempt() {
	      var maxY = Math.max(document.documentElement.scrollHeight, document.body.scrollHeight) - window.innerHeight;
	      if (maxY >= y || Date.now() > deadline) {
	        var target = Math.min(y, Math.max(maxY, 0));
	        driven = { y: target, until: Date.now() + 500 };
	        window.scrollTo(0, target);
	        if (caret != null && window.__mdPlaceCaret) { window.__mdPlaceCaret(caret, length || 0); }
	      } else {
	        // setTimeout, not requestAnimationFrame: rAF doesn't run in
	        // occluded windows, and the restore must not depend on visibility.
	        window.setTimeout(attempt, 16);
	      }
	    }
	    attempt();
	  };
	  // In-place content update from the host (debounced re-render while the
	  // user types in the other pane of a split). Swapping the body avoids a
	  // navigation — no blank flash, scroll position preserved. The editor
	  // page re-arms its per-content state via __mdAfterSwap.
	  window.__mdSwapContent = function (html) {
	    document.body.innerHTML = html;
	    if (window.__mdAfterSwap) { window.__mdAfterSwap(); }
	  };
	  report();
	})();
	"""
}
#endif
