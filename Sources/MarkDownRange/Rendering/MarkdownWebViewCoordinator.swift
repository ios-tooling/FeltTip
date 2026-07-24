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
		var lastKey: String?
		/// The non-text part of `lastKey`; a mismatch means CSS/config changed
		/// and the page needs a real reload rather than a body swap.
		var lastConfigSignature: String?
		/// Debounced in-place body update for external text changes (typing in
		/// the raw pane of a split re-renders the preview through here).
		var pendingSwap: Task<Void, Never>?
		/// The source produced by our own last edit. When the resulting
		/// `session.text` update comes back through `load`, we skip the reload so
		/// the live contentEditable DOM (which already shows the edit) isn't torn
		/// down. Matched on the actual text, not a composite key, so it's robust
		/// against theme-signature churn.
		var selfEditedText: String?
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
		/// Logs the edit bridge to the console (every message, splice, and
		/// rejection). Toggle without rebuilding:
		/// `defaults write <bundle-id> MDRDebugEditing -bool true`.
		static let debugEditing = UserDefaults.standard.bool(forKey: "MDRDebugEditing")
		/// Host-supplied change indicators, re-sent after every reload or body
		/// swap (both rebuild the DOM the edge markers hang off).
		var currentLineChanges: MarkdownLineChanges?
		private var lastSentLineChangesJSON: String?

		init(parent: MarkdownWebView) {
			self.parent = parent
		}

		func configSignature() -> String {
			"\(parent.isEditable)|\(parent.onCheckboxToggle != nil)|\(parent.renderMermaid)|\(parent.theme.signature)|\(parent.fontSize)|\(parent.baseURL?.absoluteString ?? "")|\(parent.contentReloadToken)"
		}

		func renderKey(text: String) -> String {
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

		func loadHTML(for text: String, into webView: WKWebView) {
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
			applyLineChanges(to: webView, force: true)
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
