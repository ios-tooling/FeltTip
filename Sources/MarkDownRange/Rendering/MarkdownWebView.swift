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
//  Stage 1 scope: plain-text insert/delete and top-level paragraph splits map
//  to the source; edits the bridge can't map unambiguously (inside code/tables,
//  style commands, structural list edits) are vetoed in `beforeinput` so the
//  source is never corrupted. Verification failures fall back to a re-render.
//

#if os(macOS)
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
	/// Apply this fraction (0…1 of scrollable height) once, after the first render.
	var initialScrollFraction: Double?

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

	/// Apply `fraction` (0…1 of scrollable height) once, after the first render.
	public func initialScrollFraction(_ fraction: Double?) -> Self {
		var copy = self
		copy.initialScrollFraction = fraction
		return copy
	}

	/// Custom scheme the page loads under so relative local-image paths resolve
	/// to it; `LocalResourceSchemeHandler` reads the files and serves the bytes.
	/// `WKWebView.loadHTMLString` refuses to load `file://` subresources, so a
	/// scheme handler is the supported way to show local images.
	static let resourceScheme = "markerlocalres"

	public func makeNSView(context: Context) -> WKWebView {
		let config = WKWebViewConfiguration()
		config.userContentController.add(WeakScriptMessageHandler(context.coordinator), name: "mdedit")
		config.setURLSchemeHandler(LocalResourceSchemeHandler(coordinator: context.coordinator), forURLScheme: Self.resourceScheme)
		let webView = WKWebView(frame: .zero, configuration: config)
		webView.navigationDelegate = context.coordinator
		webView.setValue(false, forKey: "drawsBackground")
		context.coordinator.webView = webView
		return webView
	}

	public func updateNSView(_ webView: WKWebView, context: Context) {
		context.coordinator.parent = self
		context.coordinator.load(into: webView)
		context.coordinator.applyScrollControls(to: webView)
	}

	public func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

	@MainActor
	public final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
		var parent: MarkdownWebView
		weak var webView: WKWebView?
		private var lastKey: String?
		/// The source produced by our own last edit. When the resulting
		/// `session.text` update comes back through `load`, we skip the reload so
		/// the live contentEditable DOM (which already shows the edit) isn't torn
		/// down. Matched on the actual text, not a composite key, so it's robust
		/// against theme-signature churn.
		private var selfEditedText: String?
		/// Last scroll position reported by the page, restored after any reload
		/// so re-renders don't jump to the top.
		private var lastScrollY: Double = 0
		/// Source offset to place the caret at after a structural re-render.
		private var pendingCaret: Int?
		/// The source the DOM currently reflects. Advanced synchronously on every
		/// edit so rapid edits chain off the right base — `parent.text` lags
		/// because the SwiftUI round-trip back into `updateNSView` is async.
		private var currentSource: String?
		/// Scroll-control tokens already applied, so a state-driven binding that
		/// survives unrelated re-renders doesn't re-scroll.
		private var lastScrollTargetToken: Int?
		private var lastScrollDeltaToken: Int?
		/// `initialScrollFraction` is applied only once, after the first render.
		private var didApplyInitialScroll = false
		/// Flip to true to log the edit bridge to the console.
		static let debugEditing = false

		init(parent: MarkdownWebView) {
			self.parent = parent
		}

		private func renderKey(text: String) -> String {
			"\(parent.isEditable)|\(parent.onCheckboxToggle != nil)|\(parent.renderMermaid)|\(parent.theme.signature)|\(parent.fontSize)|\(parent.baseURL?.absoluteString ?? "")|\(parent.contentReloadToken)|\(text.hashValue)"
		}

		func load(into webView: WKWebView) {
			// Our own edit coming back round-trip — the DOM already shows it.
			if let edited = selfEditedText, parent.text == edited {
				selfEditedText = nil
				lastKey = renderKey(text: parent.text)
				return
			}
			let key = renderKey(text: parent.text)
			guard key != lastKey else { return }
			lastKey = key
			currentSource = parent.text
			let html = MarkdownHTMLRenderer.renderDocument(
				markdown: parent.text, theme: parent.theme, fontSize: parent.fontSize,
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
			if let caret = pendingCaret {
				pendingCaret = nil
				webView.evaluateJavaScript("window.__mdPlaceCaret && window.__mdPlaceCaret(\(caret));", completionHandler: nil)
			} else if !didApplyInitialScroll, let initial = parent.initialScrollFraction {
				didApplyInitialScroll = true
				webView.evaluateJavaScript("window.__mdScrollToFraction && window.__mdScrollToFraction(\(initial));", completionHandler: nil)
			} else if lastScrollY > 0 {
				webView.evaluateJavaScript("window.scrollTo(0, \(lastScrollY));", completionHandler: nil)
			}
		}

		/// Apply token-gated scroll controls (target/delta) from the host.
		func applyScrollControls(to webView: WKWebView) {
			if let target = parent.scrollTarget, target.token != lastScrollTargetToken {
				lastScrollTargetToken = target.token
				webView.evaluateJavaScript("window.__mdScrollToFraction && window.__mdScrollToFraction(\(target.topFraction));", completionHandler: nil)
			}
			if let delta = parent.scrollDelta, delta.token != lastScrollDeltaToken {
				lastScrollDeltaToken = delta.token
				webView.evaluateJavaScript("window.__mdScrollByPixels && window.__mdScrollByPixels(\(delta.deltaY));", completionHandler: nil)
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
			// Task-list checkbox click (QuickLook): map index → source and write.
			if body["type"] as? String == "checkbox" {
				if let index = body["index"] as? Int, let checked = body["checked"] as? Bool {
					parent.onCheckboxToggle?(index, checked)
				}
				return
			}
			log("message \(body)")
			guard let start = body["start"] as? Int, let end = body["end"] as? Int else { return }
			let source = (currentSource ?? parent.text) as NSString
			let expected = body["expected"] as? String ?? ""
			// If we can't map the edit safely, leave the source untouched and the
			// DOM as-is (non-destructive) rather than reverting the user's edit.
			// A mismatch means the offsets are off — log it so we can fix mapping.
			guard start >= 0, end >= start, end <= source.length else {
				log("out-of-bounds start=\(start) end=\(end) len=\(source.length)")
				return
			}
			let range = NSRange(location: start, length: end - start)
			let actual = source.substring(with: range)
			guard actual == expected else {
				log("verify mismatch range=\(range) expected=\(quoted(expected)) actual=\(quoted(actual))")
				return
			}
			let newSource: String
			if body["op"] as? String == "wrap", let marker = body["marker"] as? String {
				newSource = source.substring(to: start) + marker + actual + marker + source.substring(from: end)
			} else if let replacement = body["text"] as? String {
				newSource = source.replacingCharacters(in: range, with: replacement)
			} else {
				return
			}
			currentSource = newSource
			log("applied range=\(range) newLen=\(newSource.count)")
			if let caret = body["caret"] as? Int {
				// Structural edit: re-render (re-stamps data-s) and restore the
				// caret. Don't suppress the reload.
				pendingCaret = caret
				parent.onSourceEdit?(newSource)
			} else {
				// In-place edit: the DOM already shows it, so skip the reload.
				selfEditedText = newSource
				lastKey = renderKey(text: newSource)
				parent.onSourceEdit?(newSource)
			}
		}

		private func log(_ message: String) {
			guard Self.debugEditing else { return }
			print("[MarkdownWebView] \(message)")
			NSLog("[MarkdownWebView] %@", message)
		}

		private func quoted(_ s: String) -> String {
			"\"\(s.replacingOccurrences(of: "\n", with: "\\n"))\""
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
	static let editorScript = """
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
	  var pending = null;

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
	  // Source offset for a DOM position, or null if it isn't inside a run.
	  function sourceOffsetOf(node, offset) {
	    var el = node.nodeType === 3 ? node.parentNode : node;
	    if (node.nodeType !== 3 && node.childNodes.length) {
	      var child = node.childNodes[Math.min(offset, node.childNodes.length - 1)];
	      if (child) el = child.nodeType === 3 ? child.parentNode : child;
	    }
	    var span = el && el.closest ? el.closest('[data-s]') : null;
	    if (!span) return null;
	    var base = parseInt(span.getAttribute('data-s'), 10);
	    var chars = textOffsetWithin(span, node, offset);
	    if (chars == null) return null;
	    return base + chars;
	  }
	  // Place the caret at a source offset after a structural re-render.
	  window.__mdPlaceCaret = function (offset) {
	    var spans = document.querySelectorAll('[data-s]');
	    for (var i = 0; i < spans.length; i++) {
	      var base = parseInt(spans[i].getAttribute('data-s'), 10);
	      var len = textLength(spans[i]);
	      if (offset >= base && offset <= base + len) {
	        var spot = locate(spans[i], offset - base);
	        if (spot) {
	          var sel = window.getSelection(), r = document.createRange();
	          r.setStart(spot.node, spot.offset); r.collapse(true);
	          sel.removeAllRanges(); sel.addRange(r);
	          spans[i].scrollIntoView({ block: 'nearest' });
	        }
	        return;
	      }
	    }
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
	    var ranges = e.getTargetRanges();
	    var range = ranges && ranges.length ? ranges[0] : null;
	    if (!range) { e.preventDefault(); return; }
	    var start = sourceOffsetOf(range.startContainer, range.startOffset);
	    var end = sourceOffsetOf(range.endContainer, range.endOffset);
	    if (start == null || end == null || end < start) { e.preventDefault(); return; }
	    var type = e.inputType, expected = rangeText(range);

	    // Fast path: in-place text edits. Let the browser mutate the DOM and
	    // mirror the change to the source (no reload).
	    if (type === 'insertText' || type === 'insertReplacementText') {
	      if (e.data == null) { e.preventDefault(); return; }
	      pending = { start: start, end: end, text: e.data, expected: expected };
	      return;
	    }
	    if (type === 'deleteContentBackward' || type === 'deleteContentForward' ||
	        type === 'deleteWordBackward' || type === 'deleteWordForward' || type === 'deleteByCut') {
	      pending = { start: start, end: end, text: '', expected: expected };
	      return;
	    }

	    // Structural edits: splice the source and re-render (re-stamps data-s),
	    // restoring the caret. Block the browser's own DOM mutation.
	    if (type === 'insertParagraph') {
	      e.preventDefault();
	      var marker = listItemMarker(range.startContainer) || '\\n\\n';
	      post({ start: start, end: end, text: marker, expected: expected, caret: start + marker.length });
	      return;
	    }
	    if (type === 'formatBold' || type === 'formatItalic') {
	      e.preventDefault();
	      if (start === end) return;  // need a selection to wrap
	      var m = type === 'formatBold' ? '**' : '*';
	      post({ op: 'wrap', marker: m, start: start, end: end, expected: expected, caret: end + 2 * m.length });
	      return;
	    }

	    e.preventDefault();  // line breaks, paste, etc. — not yet mapped
	  });
	  document.body.addEventListener('input', function () {
	    if (pending) { window.webkit.messageHandlers.mdedit.postMessage(pending); pending = null; }
	  });
	  // Report scroll so a reload can restore the reader's place.
	  window.addEventListener('scroll', function () {
	    window.webkit.messageHandlers.mdedit.postMessage({ type: 'scroll', y: window.scrollY });
	  }, { passive: true });
	})();
	"""

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
	  function report() {
	    var h = docHeight();
	    var vis = window.innerHeight;
	    var y = window.scrollY || window.pageYOffset || 0;
	    var top = Math.max(0, Math.min(1, y / h));
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
	    var centerY = Math.max(0, Math.min(1, f)) * h;
	    var y = Math.max(0, Math.min(maxY, centerY - vis / 2));
	    window.scrollTo(0, y);
	  };
	  window.__mdScrollByPixels = function (dy) { window.scrollBy(0, dy); };
	  report();
	})();
	"""
}
#endif
