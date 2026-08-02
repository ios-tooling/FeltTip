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
		guard message.name == "mdedit",
			  message.frameInfo.isMainFrame,
			  message.webView === webView,
			  isTrustedDocumentURL(message.frameInfo.request.url),
			  let body = message.body as? [String: Any]
		else {
			bridgeIncidents.append("rejected message from untrusted frame/origin")
			return
		}
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
			log("selection message start=\(body["start"] ?? "nil") length=\(body["length"] ?? "nil") handler=\(parent.onSelectionChanged != nil || parent.onSourceSelectionChanged != nil)")
			if let start = body["start"] as? Int, let length = body["length"] as? Int {
				var range = NSRange(location: start, length: length)
				if body["endAtBlockStart"] as? Bool == true,
				   length > 0 {
					let source = (currentSource ?? parent.text) as NSString
					if let blockStart = MarkdownEditSplicer.verifiedBlockStart(
						in: source, visibleStart: range.upperBound),
					   blockStart >= start {
						range.length = blockStart - start
					}
				}
				if length > 0,
				   let expanded = MarkdownEditSplicer.syntaxExpandedRange(
					range,
					syntaxStart: body["syntaxStart"] as? [String] ?? [],
					syntaxEnd: body["syntaxEnd"] as? [String] ?? [],
					in: (currentSource ?? parent.text) as NSString) {
					range = expanded
				}
				parent.onSourceSelectionChanged?(range)
				parent.onSelectionChanged?(length > 0 ? range : nil)
			} else {
				parent.onSourceSelectionChanged?(nil)
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
			guard let index = body["index"] as? Int,
			      let checked = body["checked"] as? Bool,
			      let rev = body["rev"] as? Int else {
				resync(caretAt: nil)
				return
			}
			if rev < reseedRev {
				droppedStaleEdits += 1
				return
			}
			guard rev == currentRev else {
				bridgeIncidents.append("rev mismatch: checkbox rev=\(rev) currentRev=\(currentRev)")
				resync(caretAt: nil)
				return
			}
			let source = currentSource ?? parent.text
			guard let current = Self.checkboxState(at: index, in: source) else {
				bridgeIncidents.append("checkbox index \(index) missing at rev \(rev)")
				resync(caretAt: nil)
				return
			}
			if current != checked {
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
		// The page froze for a structural edit but the re-render that should
		// clear it never arrived — a lifecycle bug somewhere upstream. Resync
		// so typing comes back instead of staying silently dead.
		if body["type"] as? String == "frozenTimeout" {
			log("frozen timeout (token \(body["token"] ?? "?")) — resyncing")
			resync(caretAt: nil)
			return
		}
		// Enter on a table's last row: append an empty row after that row's
		// line and land the caret in the new row's first cell.
		if body["type"] as? String == "appendTableRow" {
			appendTableRow(body)
			return
		}
		log("message \(body)")
		var payload = body
		// A paste carries no text: the page can't read the clipboard faithfully
		// (WebKit sanitizes the plain-text flavor of a paste's dataTransfer, and
		// a multi-line paste reaches the page with its newlines stripped), so it
		// reports the range and the pasteboard's own string fills it in.
		// Everything after this — revision gate, context verification,
		// structural re-render — is the ordinary edit path.
		if body["op"] as? String == "paste" {
			guard let pasted = Self.pasteboardText(foldingNewlines: body["inCell"] as? Bool == true) else {
				log("paste with nothing usable on the pasteboard")
				if let token = body["seq"] as? Int {
					webView?.evaluateJavaScript("window.__mdUnfreeze && window.__mdUnfreeze(\(token));", completionHandler: nil)
				}
				return
			}
			payload["text"] = pasted
			payload["caret"] = (body["start"] as? Int ?? 0) + (pasted as NSString).length
		}
		guard let edit = MarkdownEditSplicer.Edit(body: payload) else { return }
		// Revision gate. Every edit declares the source revision its offsets
		// address. A pre-reseed straggler raced a reload/swap that already
		// replaced its DOM — drop it. Any other mismatch means the page and
		// the source genuinely disagree — resync, never guess.
		if let rev = body["rev"] as? Int {
			if rev < reseedRev {
				droppedStaleEdits += 1
				log("dropping stale edit rev=\(rev) (reseeded at \(reseedRev)) seq=\(body["seq"] ?? "?")")
				return
			}
			if rev != currentRev {
				bridgeIncidents.append("rev mismatch: message rev=\(rev) currentRev=\(currentRev) seq=\(body["seq"] ?? "?") body=\(body)")
				log("rev mismatch: message rev=\(rev) currentRev=\(currentRev) seq=\(body["seq"] ?? "?") — resyncing")
				resync(caretAt: min(max(0, edit.start), ((currentSource ?? parent.text) as NSString).length))
				return
			}
		}
		let source = currentSource ?? parent.text
		switch MarkdownEditSplicer.apply(edit, to: source) {
		case .applied(let newSource, let selection):
			currentSource = newSource
			currentRev += 1
			log("applied start=\(edit.start) end=\(edit.end) newLen=\(newSource.count) rev=\(currentRev)")
			// Post-edit caret in the new source, forwarded so the host's undo
			// bookkeeping doesn't have to guess it from a text diff (which is
			// ambiguous when the edit repeats the surrounding characters).
			let caretHint = selection?.upperBound
				?? edit.start + ((edit.replacement ?? "") as NSString).length
			if edit.caret != nil, let selection {
				// Structural edit: re-render (re-stamps data-s) and restore
				// the selection (style toggles keep their selection alive;
				// other edits collapse to a caret). Don't suppress the reload.
				pendingSelection = selection
				parent.onSourceEdit?(newSource, caretHint)
			} else {
				// In-place edit: the DOM already shows it (and the page shifted
				// its own data-s stamps and advanced its stampRev in step), so
				// skip the reload.
				selfEdit = SelfEdit(rev: currentRev, text: newSource)
				lastRenderedText = newSource
				parent.onSourceEdit?(newSource, caretHint)
			}
		case .rejected(let reason):
			// Structural edits (those carrying a caret target) were
			// preventDefault'ed on the page — the DOM never mutated, so a
			// refusal (e.g. the collapsed cross-run delete guard protecting
			// hidden syntax) leaves nothing out of sync. Thaw the page and
			// drop the keystroke as a deliberate no-op.
			if edit.caret != nil, let token = body["seq"] as? Int {
				vetoedEdits += 1
				log("vetoed structural edit seq=\(token): \(reason)")
				webView?.evaluateJavaScript("window.__mdUnfreeze && window.__mdUnfreeze(\(token));", completionHandler: nil)
				return
			}
			// A fast-path edit failed verification at a matching revision:
			// the browser already mutated the DOM, and the page's text and
			// the source genuinely disagree — a real bridge bug. Log loudly
			// and resync; the user loses one keystroke, never file content.
			hardRejections += 1
			bridgeIncidents.append("REJECTED at rev \(currentRev): \(reason)")
			log("REJECTED at matching rev \(currentRev): \(reason)")
			resync(caretAt: min(max(0, edit.start), (source as NSString).length))
		}
	}

	/// The clipboard's plain text, with line endings normalized. Nil when there
	/// is nothing pastable. Inside a table cell newlines fold to spaces: a
	/// newline would shatter the row, and a cell can't show one anyway.
	static func pasteboardText(foldingNewlines: Bool) -> String? {
		guard let raw = NSPasteboard.general.string(forType: .string), !raw.isEmpty else { return nil }
		var text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
		if foldingNewlines {
			text = text.split(separator: "\n", omittingEmptySubsequences: true)
				.map { $0.trimmingCharacters(in: .whitespaces) }
				.joined(separator: " ")
		}
		return text.isEmpty ? nil : text
	}

	/// State of the document-wide indexed task-list marker. Checkbox messages
	/// are revision-gated first, then verified against source so a stale DOM
	/// index can never toggle a different item.
	private static let checkboxPattern = try! NSRegularExpression(
		pattern: #"(?m)^\s*(?:[-*+]|\d+[.)]) +\[([ xX])\]"#)

	static func checkboxState(at target: Int, in source: String) -> Bool? {
		guard target >= 0 else { return nil }
		let nsSource = source as NSString
		let range = NSRange(location: 0, length: nsSource.length)
		var current = 0
		var state: Bool?
		checkboxPattern.enumerateMatches(
			in: source, range: range
		) { match, _, stop in
			guard let match else { return }
			if current == target {
				let marker = nsSource.substring(with: match.range(at: 1))
				state = marker.lowercased() == "x"
				stop.pointee = true
			}
			current += 1
		}
		return state
	}

	/// Splice a fresh empty row after the line containing `at` (a stamp from
	/// the table's last row) and re-render with the caret in the new row's
	/// first cell. Lives here rather than in the page because only the source
	/// knows where the row's line ends. The page froze before posting, so
	/// every early out must thaw (or resync) to keep typing alive.
	private func appendTableRow(_ body: [String: Any]) {
		func thaw() {
			guard let seq = body["seq"] as? Int else { return }
			webView?.evaluateJavaScript("window.__mdUnfreeze && window.__mdUnfreeze(\(seq));", completionHandler: nil)
		}
		if let rev = body["rev"] as? Int {
			if rev < reseedRev {
				droppedStaleEdits += 1
				thaw()
				return
			}
			if rev != currentRev {
				bridgeIncidents.append("rev mismatch: appendTableRow rev=\(rev) currentRev=\(currentRev)")
				log("rev mismatch on appendTableRow — resyncing")
				resync(caretAt: nil)
				return
			}
		}
		let source = currentSource ?? parent.text
		let ns = source as NSString
		guard let at = body["at"] as? Int, let columns = body["columns"] as? Int,
			  columns > 0, at >= 0, at < ns.length else { thaw(); return }
		let tail = NSRange(location: at, length: ns.length - at)
		let newlineAt = ns.range(of: "\n", range: tail).location
		let lineEnd = newlineAt == NSNotFound ? ns.length : newlineAt
		let row = "\n|" + String(repeating: "   |", count: columns)
		currentSource = ns.substring(to: lineEnd) + row + ns.substring(from: lineEnd)
		currentRev += 1
		log("appendTableRow columns=\(columns) after line ending \(lineEnd) rev=\(currentRev)")
		// The renderer stamps an empty cell's caret home on its second padding
		// column — lineEnd + "\n|" + one space puts that at lineEnd + 3.
		pendingSelection = NSRange(location: lineEnd + 3, length: 0)
		parent.onSourceEdit?(currentSource ?? "", lineEnd + 3)
	}

	/// Reload the page from `currentSource` — not `parent.text`, which lags
	/// an in-flight SwiftUI round-trip — re-stamping every run and opening a
	/// fresh revision epoch so in-flight messages from the torn-down DOM are
	/// dropped rather than spliced.
	func resync(caretAt caret: Int?) {
		guard let webView else { return }
		resyncCount += 1
		let source = currentSource ?? parent.text
		pendingSwap?.cancel()
		pendingSwap = nil
		pendingHostText = nil
		renderTask?.cancel()
		renderTask = nil
		selfEdit = nil
		pendingSelection = caret.map { NSRange(location: $0, length: 0) }
		lastRenderedText = source
		lastConfigSignature = configSignature()
		bumpEpoch()
		loadHTML(for: source, into: webView)
	}
}
#endif
