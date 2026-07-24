//
//  MarkdownWebViewEditBridge.swift
//  MarkDownRange
//
//  The Swift side of the contentEditable edit bridge: receives the page's
//  edit messages, verifies and splices them into the Markdown source via
//  `MarkdownEditSplicer`, and resyncs (full re-render) when an edit can't be
//  applied safely.
//

#if os(macOS)
import AppKit
import WebKit

extension MarkdownWebView.Coordinator {
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
	func resync(caretAt caret: Int?) {
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
}
#endif
