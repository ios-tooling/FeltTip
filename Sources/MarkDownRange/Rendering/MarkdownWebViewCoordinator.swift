//
//  MarkdownWebViewCoordinator.swift
//  MarkDownRange
//
//  The web view's coordinator: decides between full (navigating) reloads and
//  debounced in-place body swaps, restores scroll/caret after re-renders, and
//  applies host-driven scroll/selection controls. The edit-message bridge
//  lives in MarkdownWebViewEditBridge.swift.
//

#if os(macOS)
import AppKit
import SwiftUI
import WebKit

extension MarkdownWebView {
	@MainActor
	public final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
		var parent: MarkdownWebView
		weak var webView: WKWebView?
		/// The exact text the page currently renders; with `lastConfigSignature`
		/// it decides whether a state update needs any render at all. A stored
		/// string, not a hash — hash collisions silently skipped reloads.
		var lastRenderedText: String?
		/// A mismatch means CSS/config changed and the page needs a real reload
		/// rather than a body swap.
		var lastConfigSignature: String?
		/// Debounced in-place body update for external text changes (typing in
		/// the raw pane of a split re-renders the preview through here).
		var pendingSwap: Task<Void, Never>?
		/// The revision of `currentSource`. Advanced on every applied splice and
		/// on every reload/swap; the page mirrors it in its `stampRev` and every
		/// edit message declares the revision its offsets address. Only an exact
		/// match is ever applied — a mismatch resyncs, a pre-reseed straggler is
		/// dropped (its DOM state was already replaced).
		var currentRev = 0
		/// The revision seeded by the most recent full reload or body swap.
		/// Messages declaring an older revision were composed against a DOM that
		/// no longer exists.
		var reseedRev = 0
		/// The source produced by our own last edit, with the revision it made
		/// current. When the resulting `session.text` update comes back through
		/// `load`, we skip the reload so the live contentEditable DOM (which
		/// already shows the edit) isn't torn down — but only while the revision
		/// still matches, so a different path arriving at identical text can't
		/// wrongly suppress a render.
		struct SelfEdit { var rev: Int; var text: String }
		var selfEdit: SelfEdit?
		/// Last scroll position reported by the page, restored after any reload
		/// so re-renders don't jump to the top.
		/// Internal (not private) so tests can seed it — the page reports it
		/// through a requestAnimationFrame throttle that headless test windows
		/// don't reliably run.
		var lastScrollY: Double = 0
		/// Selection (offset + length; length 0 = caret) to restore after a
		/// structural re-render. Style toggles restore the full selection so
		/// repeated ⌘B/⌘I keep operating on the same text.
		var pendingSelection: NSRange?
		/// The source the DOM currently reflects. Advanced synchronously on every
		/// edit so rapid edits chain off the right base — `parent.text` lags
		/// because the SwiftUI round-trip back into `updateNSView` is async.
		var currentSource: String?
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
		/// Renders happen off the main actor; each new render bumps this and a
		/// finished render only lands while its generation is still current, so
		/// a slow render of stale text can't overwrite a newer page.
		private var renderGeneration = 0
		/// Logs the edit bridge to the console (every message, splice, and
		/// rejection). Toggle without rebuilding:
		/// `defaults write <bundle-id> MDRDebugEditing -bool true`.
		static let debugEditing = UserDefaults.standard.bool(forKey: "MDRDebugEditing")
		/// Host-supplied change indicators, re-sent after every reload or body
		/// swap (both rebuild the DOM the edge markers hang off).
		var currentLineChanges: MarkdownLineChanges?
		private var lastSentLineChangesJSON: String?
		/// Diagnostics counters (also asserted by the edit-bridge test suites):
		/// a healthy session never resyncs, drops, or hard-rejects.
		var resyncCount = 0
		var droppedStaleEdits = 0
		var hardRejections = 0
		/// Structural edits refused on safety grounds (DOM untouched) — a
		/// user-visible no-op, not an incident.
		var vetoedEdits = 0
		/// Why each resync/rejection happened, for test failure messages.
		var bridgeIncidents: [String] = []

		init(parent: MarkdownWebView) {
			self.parent = parent
		}

		func configSignature() -> String {
			"\(parent.isEditable)|\(parent.onCheckboxToggle != nil)|\(parent.renderMermaid)|\(parent.theme.signature)|\(parent.fontSize)|\(parent.baseURL?.absoluteString ?? "")|\(parent.contentReloadToken)"
		}

		/// Advance to a fresh revision epoch. Called whenever the page's DOM is
		/// (about to be) rebuilt — full reload or body swap — so that edit
		/// messages composed against the previous DOM identify themselves as
		/// stale and get dropped instead of spliced into the wrong source.
		func bumpEpoch() {
			currentRev += 1
			reseedRev = currentRev
		}

		func load(into webView: WKWebView) {
			// Our own edit coming back round-trip — the DOM already shows it.
			let config = configSignature()
			if let edit = selfEdit, parent.text == edit.text, currentRev == edit.rev {
				selfEdit = nil
				if parent.text == lastRenderedText, config == lastConfigSignature { return }
			}
			guard parent.text != lastRenderedText || config != lastConfigSignature else { return }
			// A full (navigating) load is needed for the first render, for
			// config changes (theme/font mean new CSS), for mermaid pages (the
			// embedded engine script doesn't survive a body swap), and for our
			// own structural edits, whose pending caret is placed in
			// `didFinish`. Everything else — the text changing under us, i.e.
			// typing in the raw pane of a split — updates the page in place
			// after a debounce, so the preview neither flashes through a blank
			// navigation nor re-renders on every keystroke.
			if lastRenderedText == nil || pendingSelection != nil || config != lastConfigSignature
				|| (parent.renderMermaid && !parent.isEditable) {
				pendingSwap?.cancel()
				pendingSwap = nil
				lastRenderedText = parent.text
				lastConfigSignature = config
				log("reload: textLen=\((parent.text as NSString).length)")
				currentSource = parent.text
				bumpEpoch()
				loadHTML(for: parent.text, into: webView)
				return
			}
			pendingSwap?.cancel()
			pendingSwap = Task { @MainActor [weak self, weak webView] in
				try? await Task.sleep(for: .milliseconds(250))
				guard !Task.isCancelled, let self, let webView else { return }
				self.pendingSwap = nil
				await self.applyBodySwap(into: webView)
			}
		}

		/// Re-render the body and swap it into the loaded page in place.
		/// Reads the freshest `parent` state at fire time — later updates may
		/// have arrived during the debounce. The render itself runs off the
		/// main actor; the swap lands only if nothing changed underneath it.
		private func applyBodySwap(into webView: WKWebView) async {
			let text = parent.text
			let config = configSignature()
			guard text != lastRenderedText || config != lastConfigSignature else { return }
			guard config == lastConfigSignature, pendingSelection == nil else {
				load(into: webView)   // needs a full load after all
				return
			}
			renderGeneration += 1
			let generation = renderGeneration
			let fragment = await MarkdownRenderService.shared.bodyFragment(
				markdown: text, theme: parent.theme, fontSize: parent.fontSize,
				includeSourceOffsets: parent.isEditable,
				interactiveCheckboxes: parent.onCheckboxToggle != nil)
			// Re-validate: a newer render, a config change, a structural edit,
			// or fresher text supersedes this result.
			guard generation == renderGeneration, configSignature() == config,
			      pendingSelection == nil, parent.text == text else { return }
			guard let encoded = try? JSONEncoder().encode(fragment),
			      let json = String(data: encoded, encoding: .utf8) else {
				lastRenderedText = text
				currentSource = text
				loadHTML(for: text, into: webView)
				return
			}
			lastRenderedText = text
			currentSource = text
			bumpEpoch()
			log("body swap: textLen=\((text as NSString).length) rev=\(currentRev)")
			webView.evaluateJavaScript("window.__mdSwapContent && window.__mdSwapContent(\(json), \(currentRev));", completionHandler: nil)
			applyLineChanges(to: webView, force: true)
		}

		func applyLineChanges(to webView: WKWebView, force: Bool = false) {
			let json = Self.lineChangesJSON(currentLineChanges)
			guard force || json != lastSentLineChangesJSON else { return }
			lastSentLineChangesJSON = json
			webView.evaluateJavaScript("window.__mdSetLineChanges && window.__mdSetLineChanges(\(json));", completionHandler: nil)
		}

		static func lineChangesJSON(_ changes: MarkdownLineChanges?) -> String {
			guard let changes else { return "null" }
			let ranges = changes.changedRanges
				.map { "{\"s\":\($0.range.lowerBound),\"e\":\($0.range.upperBound),\"k\":\"\($0.kind == .added ? "a" : "m")\"}" }
				.joined(separator: ",")
			let deletions = changes.deletionOffsets.map(String.init).joined(separator: ",")
			return "{\"ranges\":[\(ranges)],\"deletions\":[\(deletions)]}"
		}

		/// Render `text` off the main actor and (still current) load it. The
		/// caller has already committed the coordinator's state for this render
		/// (lastRenderedText/currentSource/epoch), so a superseded render just
		/// never navigates — the newer call's page wins.
		func loadHTML(for text: String, into webView: WKWebView) {
			renderGeneration += 1
			let generation = renderGeneration
			let theme = parent.theme
			let fontSize = parent.fontSize
			let includeOffsets = parent.isEditable
			let checkboxes = parent.onCheckboxToggle != nil
			// Render mermaid as diagrams when the host opted in and we're not
			// editing (editing keeps the raw, editable source). The engine
			// loads through our scheme handler instead of being inlined.
			let embedMermaid = parent.renderMermaid && !parent.isEditable
			let baseURL = resourceBaseURL(for: parent.baseURL) ?? parent.baseURL
			Task { @MainActor [weak self, weak webView] in
				let html = await MarkdownRenderService.shared.documentHTML(
					markdown: text, theme: theme, fontSize: fontSize,
					includeSourceOffsets: includeOffsets, interactiveCheckboxes: checkboxes,
					embedMermaidEngine: embedMermaid)
				guard let self, let webView, generation == self.renderGeneration else { return }
				// Load under the custom resource scheme (when we have a document
				// folder) so relative <img> paths resolve to the scheme handler,
				// which can actually read local files — WKWebView won't load
				// file:// subresources of an loadHTMLString page.
				webView.loadHTMLString(html, baseURL: baseURL)
			}
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
			applyLineChanges(to: webView, force: true)
			if parent.isEditable {
				webView.evaluateJavaScript(Self.editorScript, completionHandler: nil)
				// Seed the freshly injected script with the revision this DOM
				// renders, so its edit messages address the right source state.
				webView.evaluateJavaScript("window.__mdSetRev && window.__mdSetRev(\(currentRev));", completionHandler: nil)
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
		/// places the caret via `__mdPlaceCaret`. Clear `selfEdit` so the
		/// reload is never skipped — even when the restored text happens to equal
		/// our last in-place edit.
		func applyCaretTarget() {
			guard let target = parent.caretTarget, target.token != lastCaretToken else { return }
			// Only the editor the user is actually in restores its caret. In a
			// split, the other (preview) pane just re-renders — arming a caret here
			// would steal first responder from the focused pane and end editing.
			// The token is consumed only once the restore is actually armed:
			// consuming it before this guard permanently lost the restore when
			// focus was momentarily elsewhere (window activation churn) — now the
			// next update pass retries.
			guard isFirstResponder else { return }
			lastCaretToken = target.token
			pendingSelection = NSRange(location: target.offset, length: 0)
			selfEdit = nil
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

		func open(_ url: URL) {
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

		func log(_ message: String) {
			guard Self.debugEditing else { return }
			print("[MarkdownWebView] \(message)")
			NSLog("[MarkdownWebView] %@", message)
		}
	}
}
#endif
