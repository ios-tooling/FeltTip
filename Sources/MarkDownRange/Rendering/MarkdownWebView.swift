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
import WebKit

public struct MarkdownWebView: NSViewRepresentable {
	let text: String
	let theme: MarkdownTheme
	let fontSize: CGFloat
	var baseURL: URL?
	var isEditable = false
	var onSourceEdit: ((String) -> Void)?

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

	public func makeNSView(context: Context) -> WKWebView {
		let config = WKWebViewConfiguration()
		config.userContentController.add(WeakScriptMessageHandler(context.coordinator), name: "mdedit")
		let webView = WKWebView(frame: .zero, configuration: config)
		webView.navigationDelegate = context.coordinator
		webView.setValue(false, forKey: "drawsBackground")
		context.coordinator.webView = webView
		return webView
	}

	public func updateNSView(_ webView: WKWebView, context: Context) {
		context.coordinator.parent = self
		context.coordinator.load(into: webView)
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
		/// Flip to true to log the edit bridge to the console.
		static let debugEditing = false

		init(parent: MarkdownWebView) {
			self.parent = parent
		}

		private func renderKey(text: String) -> String {
			"\(parent.isEditable)|\(parent.theme.signature)|\(parent.fontSize)|\(parent.baseURL?.absoluteString ?? "")|\(text.hashValue)"
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
			let html = MarkdownHTMLRenderer.renderDocument(
				markdown: parent.text, theme: parent.theme, fontSize: parent.fontSize,
				includeSourceOffsets: parent.isEditable)
			webView.loadHTMLString(html, baseURL: parent.baseURL)
		}

		// MARK: Navigation

		public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
			guard parent.isEditable else { return }
			webView.evaluateJavaScript(Self.editorScript, completionHandler: nil)
			if lastScrollY > 0 {
				webView.evaluateJavaScript("window.scrollTo(0, \(lastScrollY));", completionHandler: nil)
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
			if url.isFileURL, Self.markdownExtensions.contains(url.pathExtension.lowercased()) {
				NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, _ in
					if document == nil { NSWorkspace.shared.open(url) }
				}
			} else {
				NSWorkspace.shared.open(url)
			}
		}

		private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

		// MARK: Edit bridge

		public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
			guard message.name == "mdedit", let body = message.body as? [String: Any] else { return }
			// Scroll position report — remembered so reloads don't jump to top.
			if body["type"] as? String == "scroll" {
				if let y = body["y"] as? Double { lastScrollY = y }
				return
			}
			guard let start = body["start"] as? Int,
				  let end = body["end"] as? Int,
				  let replacement = body["text"] as? String else { return }
			let source = parent.text as NSString
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
				log("verify mismatch range=\(range) expected=\(quoted(expected)) actual=\(quoted(actual)) replacement=\(quoted(replacement))")
				return
			}
			let newSource = source.replacingCharacters(in: range, with: replacement)
			log("applied range=\(range) replacement=\(quoted(replacement))")
			// Skip the reload this triggers — the DOM already shows the change.
			selfEditedText = newSource
			lastKey = renderKey(text: newSource)
			parent.onSourceEdit?(newSource)
		}

		private func log(_ message: String) {
			if Self.debugEditing { print("[MarkdownWebView] \(message)") }
		}

		private func quoted(_ s: String) -> String {
			"\"\(s.replacingOccurrences(of: "\n", with: "\\n"))\""
		}
	}
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
	/// Injected after each editable load. Maps contentEditable edits to source
	/// splices via `data-s` offsets, vetoing anything it can't map.
	static let editorScript = """
	(function () {
	  if (window.__mdEditorInstalled) { document.body.contentEditable = 'true'; return; }
	  window.__mdEditorInstalled = true;
	  document.body.contentEditable = 'true';
	  document.body.style.outline = 'none';
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
	  function topLevelParagraph(node) {
	    var el = node.nodeType === 3 ? node.parentNode : node;
	    var block = el && el.closest ? el.closest('p,h1,h2,h3,h4,h5,h6') : null;
	    return block && block.parentElement === document.body;
	  }
	  function replacementFor(type, data, range) {
	    switch (type) {
	      case 'insertText':
	      case 'insertReplacementText':
	        return data == null ? null : data;
	      case 'insertParagraph':
	        return topLevelParagraph(range.startContainer) ? '\\n\\n' : null;
	      case 'deleteContentBackward':
	      case 'deleteContentForward':
	      case 'deleteWordBackward':
	      case 'deleteWordForward':
	      case 'deleteByCut':
	        return '';
	      default:
	        return null; // styles, lists, line breaks, paste — not yet mapped
	    }
	  }

	  document.body.addEventListener('beforeinput', function (e) {
	    var ranges = e.getTargetRanges();
	    var range = ranges && ranges.length ? ranges[0] : null;
	    if (!range) { e.preventDefault(); return; }
	    var start = sourceOffsetOf(range.startContainer, range.startOffset);
	    var end = sourceOffsetOf(range.endContainer, range.endOffset);
	    if (start == null || end == null || end < start) { e.preventDefault(); return; }
	    var replacement = replacementFor(e.inputType, e.data, range);
	    if (replacement == null) { e.preventDefault(); return; }
	    pending = { start: start, end: end, text: replacement, expected: range.toString() };
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
}
#endif
