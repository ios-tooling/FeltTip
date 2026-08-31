//
//  MarkdownWebViewEditBridge.swift
//  MarkDownRange
//
//  The Swift side of the contentEditable edit bridge: receives the page's
//  edit messages, verifies and splices them into the Markdown source via
//  `MarkdownEditSplicer`, and resyncs (full re-render) when an edit can't be
//  applied safely.
//

import WebKit
#if os(macOS)
	import AppKit
#else
	import UIKit
#endif

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
		if body["type"] as? String == "initialReady" {
			// User scripts run at document-end, before WKNavigationDelegate's
			// didFinish callback. At this point the DOM and edit bridge are live,
			// so the page is genuinely interactive and can satisfy first-render
			// readiness without waiting on later navigation bookkeeping.
			if let webView = message.webView, usesDocumentEndScripts {
				completePageSetup(in: webView)
			}
			return
		}
		if body["type"] as? String == "selection" {
			log("selection message start=\(body["start"] ?? "nil") length=\(body["length"] ?? "nil") handler=\(parent.onSelectionChanged != nil || parent.onSourceSelectionChanged != nil)")
			guard let revision = body["rev"] as? Int else {
				log("dropping selection without a revision")
				return
			}
			if revision != currentRev {
				log("dropping stale selection rev=\(revision) currentRev=\(currentRev)")
				return
			}
			if let start = body["start"] as? Int, let length = body["length"] as? Int {
				let source = (currentSource ?? parent.text) as NSString
				guard start >= 0, length >= 0, start <= source.length,
				      length <= source.length - start else {
					log("dropping out-of-bounds selection start=\(start) length=\(length) sourceLen=\(source.length)")
					return
				}
				var range = NSRange(location: start, length: length)
				if body["endAtBlockStart"] as? Bool == true,
				   length > 0 {
					if let blockStart = MarkdownEditSplicer.verifiedBlockStart(
						in: source, visibleStart: range.upperBound),
					   blockStart >= start {
						var selectionEnd = blockStart
						// WebKit's paragraph range includes the separator before
						// the following block. The styled selection has no visible
						// ownership of those blank source lines, so keep them out
						// of the raw-pane mirror while retaining attached syntax.
						while selectionEnd > start {
							let character = source.character(at: selectionEnd - 1)
							if character == 0x09 || character == 0x0A ||
							   character == 0x0D || character == 0x20 {
								selectionEnd -= 1
							} else {
								break
							}
						}
						range.length = selectionEnd - start
					}
				}
				if length > 0,
				   let expanded = MarkdownEditSplicer.syntaxExpandedRange(
					range,
					syntaxStart: body["syntaxStart"] as? [String] ?? [],
					syntaxEnd: body["syntaxEnd"] as? [String] ?? [],
					in: source) {
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
		if body["type"] as? String == "openImage" {
			guard let source = body["source"] as? String,
			      let request = imageRequest(source: source, altText: body["alt"] as? String ?? "")
			else { return }
			parent.onOpenImage?(request)
			return
		}
		if body["type"] as? String == "previewLink" {
			guard let href = body["href"] as? String,
			      let requestURL = URL(string: href),
			      let requestID = body["requestID"] as? Int,
			      let accessPolicy = localResourceAccessPolicy else { return }
			linkPreviewTask?.cancel()
			linkPreviewTask = Task { @MainActor [weak self, weak webView] in
				let preview = await MarkdownLinkPreviewLoader.load(
					requestURL: requestURL, accessPolicy: accessPolicy)
				guard let self, let webView, !Task.isCancelled else { return }
				self.linkPreviewTask = nil
				self.sendLinkPreview(preview, requestID: requestID, to: webView)
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
			lastResyncReason =
				"page desync caret=\(body["caret"] ?? "?") rev=\(body["rev"] ?? "?") seq=\(body["seq"] ?? "?") detail=\(body["detail"] ?? "?")"
			log("desync reported by page")
			// A drift-triggered resync knows where the caret belongs, because
			// the edit that caused it said so. Without that the caret would
			// land wherever the rebuilt DOM happens to put it.
			resync(caretAt: body["caret"] as? Int)
			return
		}
		// The page froze for a structural edit but the re-render that should
		// clear it never arrived — a lifecycle bug somewhere upstream. Resync
		// so typing comes back instead of staying silently dead.
		if body["type"] as? String == "frozenTimeout" {
			lastResyncReason = "frozen timeout token=\(body["token"] ?? "?")"
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
		// Every source-mutating page message must identify the exact source
		// revision its offsets address. Gate this before pasteboard access or
		// payload expansion so stale/malformed messages are cheap no-ops and can
		// never borrow the host's current clipboard contents.
		guard let rev = body["rev"] as? Int else {
			bridgeIncidents.append("edit without revision seq=\(body["seq"] ?? "?")")
			log("edit without revision seq=\(body["seq"] ?? "?") — resyncing")
			resync(caretAt: nil)
			return
		}
		if rev < reseedRev {
			droppedStaleEdits += 1
			log("dropping stale edit rev=\(rev) (reseeded at \(reseedRev)) seq=\(body["seq"] ?? "?")")
			return
		}
		if rev != currentRev {
			bridgeIncidents.append("rev mismatch: message rev=\(rev) currentRev=\(currentRev) seq=\(body["seq"] ?? "?") body=\(body)")
			log("rev mismatch: message rev=\(rev) currentRev=\(currentRev) seq=\(body["seq"] ?? "?") — resyncing")
			let sourceLength = ((currentSource ?? parent.text) as NSString).length
			let caret = (body["start"] as? Int).map { min(max(0, $0), sourceLength) }
			resync(caretAt: caret)
			return
		}
		let source = currentSource ?? parent.text
		var payload = body
		var canonicalReplacementTransform: ((String) -> String)?
		var canonicalCaretAfterInsertedText: ((String) -> Int)?
		// Synthetic empty-wrapper caret homes have no source-backed DOM endpoint.
		// Their selection route supplies exact mapped offsets instead; now that
		// the revision is verified, fill in the canonical source spelling so
		// hidden Markdown delimiters cannot make an otherwise valid Cut, selected
		// deletion, or paste fail visible-text verification.
		if body["canonicalSelection"] as? Bool == true {
			let sourceText = source as NSString
			guard let operation = body["op"] as? String,
			      operation == "paste" || operation == "cut" ||
			      operation == "deleteSelection" || operation == "replaceSelection" ||
			      operation == "format",
			      body["selected"] as? Bool == true,
			      let start = body["start"] as? Int,
			      let end = body["end"] as? Int,
			      start >= 0, end >= start, end <= sourceText.length,
			      let inlineCaretOffset = body["inlineCaretOffset"] as? Int,
			      let wrapperRange = Self.emptyUnderlineClusterRange(
					in: sourceText,
					caret: inlineCaretOffset,
					afterWrapper: body["inlineCaretAfterWrapper"] as? Bool == true,
					beforeWrapper: body["inlineCaretBeforeWrapper"] as? Bool == true),
			      let expandedRange = MarkdownEditSplicer.syntaxExpandedRange(
					NSRange(location: start, length: end - start),
					syntaxStart: body["syntaxStart"] as? [String] ?? [],
					syntaxEnd: body["syntaxEnd"] as? [String] ?? [],
					in: sourceText),
			      body["selectionStartsAtHome"] as? Bool == true
					? expandedRange.location == wrapperRange.upperBound
					: expandedRange.upperBound == wrapperRange.location else {
				bridgeIncidents.append("invalid canonical synthetic-caret selection")
				resync(caretAt: body["start"] as? Int)
				return
			}
			var adjustedStart = start
			var adjustedEnd = end
			let syntaxStart = body["syntaxStart"] as? [String] ?? []
			let syntaxEnd = body["syntaxEnd"] as? [String] ?? []
			let visibleSelection = (body["expected"] as? String ?? "")
				.trimmingCharacters(in: .whitespacesAndNewlines)
			if operation == "format", !visibleSelection.isEmpty {
				let expandedSource = sourceText.substring(with: expandedRange) as NSString
				let localVisible = expandedSource.range(of: visibleSelection)
				if localVisible.location != NSNotFound {
					// Native word selection owns adjacent visual whitespace, but
					// inline Markdown delimiters may not: `** word**` does not
					// render as the requested bold word. Find the visible content
					// inside the verified syntax-expanded interval so an existing
					// complete wrapper can still be toggled off.
					adjustedStart = expandedRange.location + localVisible.location
					adjustedEnd = adjustedStart + localVisible.length
					payload["crossRun"] = false
					payload["syntaxStart"] = []
					payload["syntaxEnd"] = []
				}
			} else if body["crossRun"] as? Bool != true,
			   syntaxStart.isEmpty, syntaxEnd.isEmpty, !visibleSelection.isEmpty {
				let selectedSource = sourceText.substring(with: NSRange(
					location: start, length: end - start)) as NSString
				let localWord = selectedSource.range(of: visibleSelection)
				if localWord.location != NSNotFound {
					let word = NSRange(
						location: start + localWord.location, length: localWord.length)
					let fullyExpandedWord = MarkdownEditSplicer.fullySyntaxExpandedInlineRange(
						word, in: sourceText)
					if fullyExpandedWord != word {
						// A complete styled word follows the ordinary owned-syntax
						// route; only a partial run needs delimiter preservation.
					} else if body["selectionStartsAtHome"] as? Bool == true {
						let prefix = Self.hiddenInlinePrefixToPreserve(
							in: sourceText, boundary: start, wordStart: word.location)
						if !prefix.isEmpty {
							while adjustedEnd < sourceText.length {
								let character = sourceText.character(at: adjustedEnd)
								guard character == 0x20 || character == 0x09 else { break }
								adjustedEnd += 1
							}
							let whitespace = sourceText.substring(with: NSRange(
								location: end, length: adjustedEnd - end))
							canonicalReplacementTransform = { $0 + whitespace + prefix }
							canonicalCaretAfterInsertedText = {
								adjustedStart + ($0 as NSString).length
							}
						}
					} else {
						let visibleBoundary = Self.visibleWordBoundaryBeforeHiddenInlineSuffix(
							in: sourceText, boundary: end)
						let suffix = Self.hiddenInlineSuffixToPreserve(
							in: sourceText, wordEnd: word.upperBound,
							visibleBoundary: visibleBoundary, boundary: end)
						if !suffix.isEmpty {
							while adjustedStart > 0 {
								let character = sourceText.character(at: adjustedStart - 1)
								guard character == 0x20 || character == 0x09 else { break }
								adjustedStart -= 1
							}
							let whitespace = sourceText.substring(with: NSRange(
								location: adjustedStart, length: start - adjustedStart))
							canonicalReplacementTransform = { inserted in
								inserted.isEmpty || inserted.contains("\n") || inserted.contains("\r")
									? suffix + whitespace + inserted
									: whitespace + inserted + suffix
							}
							canonicalCaretAfterInsertedText = { inserted in
								let prefix = inserted.contains("\n") || inserted.contains("\r")
									? suffix + whitespace : whitespace
								return adjustedStart + (prefix as NSString).length +
									(inserted as NSString).length
							}
						}
					}
				}
			}
			if body["blockBoundary"] as? Bool == true,
			   (operation == "cut" || operation == "deleteSelection" ||
			    operation == "replaceSelection"),
			   body["selectionStartsAtHome"] as? Bool != true,
			   !visibleSelection.isEmpty {
				let selectedSource = sourceText.substring(with: NSRange(
					location: adjustedStart, length: adjustedEnd - adjustedStart)) as NSString
				let visibleRange = selectedSource.range(of: visibleSelection)
				if visibleRange.location != NSNotFound {
					if let preserved = Self.blockBoundaryHiddenSuffix(
						in: selectedSource, visibleEnd: visibleRange.upperBound) {
						canonicalReplacementTransform = operation == "replaceSelection"
							? { $0 + preserved }
							: { _ in preserved }
					}
				}
			}
			payload["start"] = adjustedStart
			payload["end"] = adjustedEnd
			payload["expected"] = sourceText.substring(with: NSRange(
				location: adjustedStart, length: adjustedEnd - adjustedStart))
			payload["before"] = ""
			payload["after"] = ""
			if operation == "cut" || operation == "deleteSelection" {
				let replacement = canonicalReplacementTransform?("") ??
					(payload["text"] as? String ?? "")
				if canonicalReplacementTransform != nil {
					payload["text"] = replacement
				}
				let replacementLength = (replacement as NSString).length
				if inlineCaretOffset >= adjustedEnd {
					payload["caret"] = inlineCaretOffset + replacementLength -
						(adjustedEnd - adjustedStart)
				} else if inlineCaretOffset <= adjustedStart {
					payload["caret"] = inlineCaretOffset
				} else {
					payload["caret"] = body["selectionStartsAtHome"] as? Bool == true
						? inlineCaretOffset
						: inlineCaretOffset - (adjustedEnd - adjustedStart) + replacementLength
				}
			} else if operation == "replaceSelection",
			          let inserted = payload["text"] as? String {
				if let transform = canonicalReplacementTransform {
					payload["text"] = transform(inserted)
				}
				payload["caret"] = canonicalCaretAfterInsertedText?(inserted) ??
					(adjustedStart + (inserted as NSString).length)
			}
		}
		if body["op"] as? String == "neutralWordDelete" {
			guard let caret = body["start"] as? Int,
			      let wrapperRange = Self.emptyUnderlineClusterRange(
					in: source as NSString,
					caret: caret,
					afterWrapper: body["afterWrapper"] as? Bool == true,
					beforeWrapper: body["beforeWrapper"] as? Bool == true),
			      let deletion = Self.adjacentWordDeletion(
					in: source,
					boundary: body["backward"] as? Bool == true
						? wrapperRange.location : wrapperRange.upperBound,
					backward: body["backward"] as? Bool == true)
			else {
				if let token = body["seq"] as? Int {
					webView?.evaluateJavaScript(
						"window.__mdUnfreeze && window.__mdUnfreeze(\(token));",
						completionHandler: nil)
				}
				return
			}
			payload["start"] = deletion.range.location
			payload["end"] = deletion.range.upperBound
			payload["text"] = deletion.replacement
			payload["expected"] = (source as NSString).substring(with: deletion.range)
			payload["before"] = ""
			payload["after"] = ""
			payload["caret"] = body["backward"] as? Bool == true
				? caret - deletion.range.length + (deletion.replacement as NSString).length
				: caret
		}
		// A paste carries no text: the page can't read the clipboard faithfully
		// (WebKit sanitizes the plain-text flavor of a paste's dataTransfer, and
		// a multi-line paste reaches the page with its newlines stripped), so it
		// reports the range and the pasteboard's own string fills it in.
		// Everything after this — revision gate, context verification,
		// structural re-render — is the ordinary edit path.
		if body["op"] as? String == "paste" {
			let isPrivateSourcePaste = body["matchStyle"] as? Bool != true &&
				MarkdownPasteboard.source != nil
			guard let pasted = Self.pasteboardText(
				foldingNewlines: body["inCell"] as? Bool == true,
				preferringSource: body["matchStyle"] as? Bool != true) else {
				log("paste with nothing usable on the pasteboard")
				if let token = body["seq"] as? Int {
					webView?.evaluateJavaScript("window.__mdUnfreeze && window.__mdUnfreeze(\(token));", completionHandler: nil)
				}
				return
			}
			payload["text"] = pasted
			if let transform = canonicalReplacementTransform {
				payload["text"] = transform(pasted)
			}
			var customCaret = canonicalCaretAfterInsertedText?(pasted)
			if isPrivateSourcePaste,
			   let start = body["start"] as? Int,
			   let origin = boundaryCutPasteOrigin,
			   origin.source == source,
			   Self.emptyUnderlineClusterStart(
				in: source as NSString, caret: start) == Self.emptyUnderlineClusterStart(
					in: source as NSString, caret: origin.wrapperStart),
			   origin.pasted == pasted,
			   origin.generation == MarkdownPasteboard.sourceGeneration,
			   let structural = Self.privateBoundaryPaste(
				in: source as NSString, caret: start, pasted: pasted,
				wrapperStart: origin.wrapperStart) {
				payload["start"] = structural.range.location
				payload["end"] = structural.range.upperBound
				payload["text"] = structural.replacement
				payload["expected"] = (source as NSString).substring(with: structural.range)
				payload["before"] = ""
				payload["after"] = ""
				payload["crossRun"] = false
				payload["selected"] = false
				payload["endAtBlockStart"] = false
				payload["syntaxStart"] = []
				payload["syntaxEnd"] = []
				payload["blockPrefixes"] = []
				customCaret = structural.caret
			} else if pasted.contains("\n"),
			   let start = body["start"] as? Int,
			   let end = body["end"] as? Int,
			   end >= start,
			   let wrapperRange = Self.inlineWrapperRangeForMultilinePaste(
				in: source as NSString,
				selection: NSRange(location: start, length: end - start)) {
				payload["start"] = wrapperRange.location
				payload["end"] = wrapperRange.upperBound
				payload["expected"] = (source as NSString).substring(with: wrapperRange)
				payload["before"] = ""
				payload["after"] = ""
				payload["crossRun"] = false
				payload["selected"] = false
				payload["endAtBlockStart"] = false
				payload["syntaxStart"] = []
				payload["syntaxEnd"] = []
				payload["blockPrefixes"] = []
			} else if pasted.contains("\n"),
			          let start = body["start"] as? Int,
			          let end = body["end"] as? Int,
			          end >= start,
			          let split = Self.multilineInlineReplacement(
					in: source as NSString,
					selection: NSRange(location: start, length: end - start),
					pasted: pasted,
					metadata: body["inlineContainer"] as? [String: Any]) {
				payload["start"] = split.range.location
				payload["end"] = split.range.upperBound
				payload["text"] = split.replacement
				payload["expected"] = (source as NSString).substring(with: split.range)
				payload["before"] = ""
				payload["after"] = ""
				payload["crossRun"] = false
				payload["selected"] = false
				payload["endAtBlockStart"] = false
				payload["syntaxStart"] = []
				payload["syntaxEnd"] = []
				payload["blockPrefixes"] = []
				customCaret = split.caret
			}
			guard let start = payload["start"] as? Int,
			      let caret = customCaret ?? Self.caretAfterInsertion(
					start: start,
					text: payload["text"] as? String ?? pasted) else {
				log("paste with invalid or overflowing start \(body["start"] ?? "nil")")
				if let token = body["seq"] as? Int {
					webView?.evaluateJavaScript(
						"window.__mdUnfreeze && window.__mdUnfreeze(\(token));",
						completionHandler: nil)
				}
				return
			}
			payload["caret"] = caret
		}
		guard let edit = MarkdownEditSplicer.Edit(body: payload) else { return }
		let isClipboardCut = body["op"] as? String == "cut"
		switch MarkdownEditSplicer.apply(edit, to: source) {
		case .applied(let newSource, let selection, let replaced):
			var wrotePrivateSource = false
			if isClipboardCut, !replaced.isEmpty {
				let clipboardExpected = body["clipboardExpected"] as? String
					?? edit.expected
				wrotePrivateSource = MarkdownPasteboard.writeSource(
					replaced, ifTextMatches: clipboardExpected)
			}
			// A preventDefault'ed structural replacement can be a source no-op
			// (select the complete `**é**` run and type the same `é`). The DOM was
			// never mutated, and SwiftUI will not re-render an unchanged binding,
			// so thaw and collapse the selection here instead of waiting for the
			// frozen-timeout recovery. Do not advance the source revision: the
			// page's stamps still address exactly the current source.
			if edit.caret != nil, newSource == source, let token = body["seq"] as? Int {
				let caretHint = selection?.upperBound
					?? edit.start + ((edit.replacement ?? "") as NSString).length
				parent.onSourceEdit?(newSource, caretHint)
				var script = "window.__mdUnfreeze && window.__mdUnfreeze(\(token));"
				script += " window.__mdPlaceCaret && window.__mdPlaceCaret(\(caretHint));"
				webView?.evaluateJavaScript(script, completionHandler: nil)
				return
			}
			currentSource = newSource
			currentRev += 1
			log("applied start=\(edit.start) end=\(edit.end) newLen=\(newSource.count) rev=\(currentRev)")
			// Post-edit caret in the new source, forwarded so the host's undo
			// bookkeeping doesn't have to guess it from a text diff (which is
			// ambiguous when the edit repeats the surrounding characters).
			let caretHint = selection?.upperBound
				?? edit.start + ((edit.replacement ?? "") as NSString).length
			let mappedInlineWrapperStart: Int? = {
				guard let inlineCaretOffset = body["inlineCaretOffset"] as? Int,
				      let originalWrapperStart = Self.emptyUnderlineStart(
						in: source as NSString, caret: inlineCaretOffset)
				else { return nil }
				let replacementLength = ((edit.replacement ?? "") as NSString).length
				let mappedStart: Int
				if originalWrapperStart >= edit.end {
					mappedStart = originalWrapperStart + replacementLength - (edit.end - edit.start)
				} else if originalWrapperStart <= edit.start {
					mappedStart = originalWrapperStart
				} else {
					return nil
				}
				return Self.emptyUnderlineStart(
					in: newSource as NSString, caret: mappedStart) == mappedStart
					? mappedStart : nil
			}()
			if isClipboardCut,
			   wrotePrivateSource,
			   let wrapperStart = mappedInlineWrapperStart ?? Self.emptyUnderlineStart(
				in: newSource as NSString, caret: caretHint)
				?? Self.emptyUnderlineStart(
					in: newSource as NSString, caret: edit.start)
				?? Self.emptyUnderlineStart(
					in: newSource as NSString,
					caret: edit.start + ((edit.replacement ?? "") as NSString).length) {
				boundaryCutPasteOrigin = BoundaryCutPasteOrigin(
					source: newSource, wrapperStart: wrapperStart, pasted: replaced,
					generation: MarkdownPasteboard.sourceGeneration)
			} else {
				boundaryCutPasteOrigin = nil
			}
			if edit.caret != nil, let selection {
				// Structural edit: re-render (re-stamps data-s) and restore
				// the selection (style toggles keep their selection alive;
				// other edits collapse to a caret). Don't suppress the reload.
				pendingSelection = selection
				pendingStructuralTailDelta = (newSource as NSString).length - (source as NSString).length
				pendingStructuralTailBoundary = edit.end
				pendingStructuralText = newSource
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

	private func sendLinkPreview(
		_ preview: MarkdownLinkPreview?,
		requestID: Int,
		to webView: WKWebView
	) {
		guard let json = Self.linkPreviewJSON(preview) else { return }
		webView.evaluateJavaScript(
			"window.__mdShowLinkPreview && window.__mdShowLinkPreview(\(requestID), \(json));",
			completionHandler: nil)
	}

	static func linkPreviewJSON(_ preview: MarkdownLinkPreview?) -> String? {
		guard let preview else { return "null" }
		let object: [String: Any] = [
			"filename": preview.filename,
			"pairs": preview.pairs.map { ["key": $0.key, "value": $0.value] }
		]
		guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
		return String(data: data, encoding: .utf8)
	}

	/// The clipboard's plain text, with line endings and non-breaking spaces
	/// normalized. Nil when there is nothing pastable. Inside a table cell
	/// newlines fold to spaces: a newline would shatter the row, and a cell
	/// can't show one anyway.
	///
	/// The U+00A0 pass is not cosmetic. contentEditable renders a lone space as
	/// a non-breaking space so layout can't collapse it, and hands that to the
	/// clipboard — so cutting the space between two words and pasting it back
	/// writes U+00A0 into the markdown. The page already flattens it in
	/// everything it reads out of the DOM (`plain()` in EditorScript.js), which
	/// means the styled view cannot show the difference: a source holding one
	/// would disagree with its own render forever. Flattening here keeps the
	/// two sides reading the same text.
	static func pasteboardText(foldingNewlines: Bool, preferringSource: Bool = true) -> String? {
		guard let raw = (preferringSource ? MarkdownPasteboard.source : nil) ?? MarkdownPasteboard.text,
		      !raw.isEmpty else { return nil }
		var text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
		text = text.replacingOccurrences(of: "\u{00A0}", with: " ")
		if foldingNewlines {
			text = text.split(separator: "\n", omittingEmptySubsequences: true)
				.map { $0.trimmingCharacters(in: .whitespaces) }
				.joined(separator: " ")
		}
		return text.isEmpty ? nil : text
	}

	static func caretAfterInsertion(start: Int, text: String) -> Int? {
		guard start >= 0 else { return nil }
		let (caret, overflow) = start.addingReportingOverflow((text as NSString).length)
		return overflow ? nil : caret
	}

	/// A collapsed format represents its pending style as an empty source
	/// wrapper around the caret. Multiline text cannot safely live inside an
	/// inline wrapper, so paste replaces this exact wrapper atomically.
	private static func inlineWrapperRangeForMultilinePaste(
		in source: NSString,
		selection: NSRange
	) -> NSRange? {
		guard selection.location >= 0, selection.length >= 0,
			  selection.upperBound <= source.length else { return nil }
		if selection.length > 0 {
			let label = source.substring(with: selection)
			guard label == "link text", selection.location > 0,
				  selection.upperBound + 3 <= source.length else { return nil }
			let wrapper = NSRange(
				location: selection.location - 1,
				length: selection.length + 4)
			return source.substring(with: wrapper) == "[link text]()"
				? wrapper : nil
		}
		let caret = selection.location
		let wrappers: [(text: String, caretOffset: Int)] = [
			("<u></u>", 3),
			("****", 2),
			("~~~~", 2),
			("====", 2),
			("**", 1),
			("__", 1),
			("``", 1),
			("^^", 1),
			("~~", 1),
		]
		for wrapper in wrappers {
			let length = (wrapper.text as NSString).length
			let start = caret - wrapper.caretOffset
			guard start >= 0, start + length <= source.length else { continue }
			let range = NSRange(location: start, length: length)
			let candidate = source.substring(with: range)
			if wrapper.text == "<u></u>" {
				if candidate.caseInsensitiveCompare(wrapper.text) == .orderedSame {
					return range
				}
			} else if candidate == wrapper.text {
				return range
			}
		}
		return nil
	}

	private struct MultilineInlineReplacement {
		let range: NSRange
		let replacement: String
		let caret: Int
	}

	/// Splits the outermost containing inline wrapper around a multiline paste.
	/// Untouched text remains wrapped on its own side of the new blocks, while
	/// the pasted paragraphs themselves stay outside inline Markdown syntax.
	private static func multilineInlineReplacement(
		in source: NSString,
		selection: NSRange,
		pasted: String,
		metadata: [String: Any]?
	) -> MultilineInlineReplacement? {
		guard let metadata,
		      let start = metadata["start"] as? Int,
		      let end = metadata["end"] as? Int,
		      end >= start,
		      selection.location >= start,
		      selection.upperBound <= end else { return nil }
		let visible = NSRange(location: start, length: end - start)
		let metadataExpanded = MarkdownEditSplicer.syntaxExpandedRange(
			visible,
			syntaxStart: metadata["syntaxStart"] as? [String] ?? [],
			syntaxEnd: metadata["syntaxEnd"] as? [String] ?? [],
			in: source)
		let initialExpanded = MarkdownEditSplicer.fullySyntaxExpandedInlineRange(
			metadataExpanded ?? visible,
			in: source)
		guard initialExpanded.location < visible.location,
		      initialExpanded.upperBound > visible.upperBound else { return nil }
		let expanded = enclosingInlineWrapperRange(
			startingAt: initialExpanded,
			in: source)
		let opening = source.substring(with: NSRange(
			location: expanded.location,
			length: visible.location - expanded.location))
		let closing = source.substring(with: NSRange(
			location: visible.upperBound,
			length: expanded.upperBound - visible.upperBound))
		let prefix = source.substring(with: NSRange(
			location: visible.location,
			length: selection.location - visible.location))
		let suffix = source.substring(with: NSRange(
			location: selection.upperBound,
			length: visible.upperBound - selection.upperBound))
		let wrappedPrefix = prefix.isEmpty ? "" : opening + prefix + closing
		let wrappedSuffix = suffix.isEmpty ? "" : opening + suffix + closing
		let replacement = wrappedPrefix + pasted + wrappedSuffix
		guard let caret = caretAfterInsertion(
			start: expanded.location,
			text: wrappedPrefix + pasted) else { return nil }
		return MultilineInlineReplacement(
			range: expanded,
			replacement: replacement,
			caret: caret)
	}

	private static func enclosingInlineWrapperRange(
		startingAt initial: NSRange,
		in source: NSString
	) -> NSRange {
		var range = initial
		while true {
			var enclosing: NSRange?
			if range.location >= 3, range.upperBound + 4 <= source.length,
			   source.substring(with: NSRange(
				location: range.location - 3, length: 3))
				.caseInsensitiveCompare("<u>") == .orderedSame,
			   source.substring(with: NSRange(
				location: range.upperBound, length: 4))
				.caseInsensitiveCompare("</u>") == .orderedSame {
				enclosing = NSRange(
					location: range.location - 3,
					length: range.length + 7)
			}
			if enclosing == nil, range.location > 0,
			   source.character(at: range.location - 1) == 0x5B,
			   range.upperBound + 2 <= source.length,
			   source.substring(with: NSRange(
				location: range.upperBound, length: 2)) == "](" {
				var offset = range.upperBound + 2
				var depth = 0
				var escaped = false
				while offset < source.length {
					let character = source.character(at: offset)
					if escaped {
						escaped = false
					} else if character == 0x5C {
						escaped = true
					} else if character == 0x28 {
						depth += 1
					} else if character == 0x29, depth > 0 {
						depth -= 1
					} else if character == 0x29 {
						enclosing = NSRange(
							location: range.location - 1,
							length: offset + 1 - range.location + 1)
						break
					}
					offset += 1
				}
			}
			if enclosing == nil {
				for marker in ["***", "___", "~~", "==", "**", "__", "*", "_", "^", "~"] {
					let length = (marker as NSString).length
					guard range.location >= length,
					      range.upperBound + length <= source.length else { continue }
					if source.substring(with: NSRange(
						location: range.location - length, length: length)) == marker,
					   source.substring(with: NSRange(
						location: range.upperBound, length: length)) == marker {
						enclosing = NSRange(
							location: range.location - length,
							length: range.length + length * 2)
						break
					}
				}
			}
			guard let enclosing, enclosing != range else { return range }
			range = enclosing
		}
	}

	private static func emptyUnderlineClusterRange(
		in source: NSString,
		caret: Int,
		afterWrapper: Bool,
		beforeWrapper: Bool = false
	) -> NSRange? {
		func isEmptyUnderline(at location: Int) -> Bool {
			guard location >= 0, location + 7 <= source.length else { return false }
			return source.substring(with: NSRange(location: location, length: 7))
				.caseInsensitiveCompare("<u></u>") == .orderedSame
		}
		var start = beforeWrapper ? caret : afterWrapper ? caret - 7 : caret - 3
		guard isEmptyUnderline(at: start) else { return nil }
		var end = start + 7
		while isEmptyUnderline(at: start - 7) { start -= 7 }
		while isEmptyUnderline(at: end) { end += 7 }
		return NSRange(location: start, length: end - start)
	}

	/// Finds the native word-deletion target next to a source-neutral inline
	/// caret. The empty HTML wrapper is invisible in the DOM, so WebKit cannot
	/// produce a useful target range for Option-Backspace/Delete itself.
	private struct AdjacentWordDeletion {
		let range: NSRange
		let replacement: String
	}

	private static func adjacentWordDeletion(
		in source: String,
		boundary: Int,
		backward: Bool
	) -> AdjacentWordDeletion? {
		let text = source as NSString
		guard boundary >= 0, boundary <= text.length else { return nil }
		let visibleBoundary = backward
			? visibleWordBoundaryBeforeHiddenInlineSuffix(in: text, boundary: boundary)
			: visibleWordBoundaryAfterHiddenInlinePrefix(in: text, boundary: boundary)
		var lineStart = boundary
		while lineStart > 0 {
			let unit = text.character(at: lineStart - 1)
			if unit == 0x0A || unit == 0x0D { break }
			lineStart -= 1
		}
		var lineEnd = boundary
		while lineEnd < text.length {
			let unit = text.character(at: lineEnd)
			if unit == 0x0A || unit == 0x0D { break }
			lineEnd += 1
		}
		guard let line = Range(
			NSRange(location: lineStart, length: lineEnd - lineStart),
			in: source) else { return nil }
		var word: NSRange?
		let options: String.EnumerationOptions = backward ? [.byWords, .reverse] : [.byWords]
		source.enumerateSubstrings(in: line, options: options) { _, range, _, stop in
			let candidate = NSRange(range, in: source)
			if backward ? candidate.upperBound <= visibleBoundary : candidate.location >= visibleBoundary {
				word = candidate
				stop = true
			}
		}
		guard let word else { return nil }
		let expandedWord = MarkdownEditSplicer.fullySyntaxExpandedInlineRange(
			word, in: text)
		var range = backward
			? NSRange(
				location: expandedWord.location,
				length: boundary - expandedWord.location)
			: NSRange(
				location: boundary,
				length: expandedWord.upperBound - boundary)
		guard expandedWord == word else {
			return AdjacentWordDeletion(range: range, replacement: "")
		}
		let preservedSyntax = backward
			? hiddenInlineSuffixToPreserve(
				in: text, wordEnd: word.upperBound,
				visibleBoundary: visibleBoundary, boundary: boundary)
			: hiddenInlinePrefixToPreserve(
				in: text, boundary: boundary, wordStart: word.location)
		guard !preservedSyntax.isEmpty else {
			return AdjacentWordDeletion(range: range, replacement: "")
		}
		if backward {
			var visibleStart = word.location
			while visibleStart > 0 {
				let character = text.character(at: visibleStart - 1)
				guard character == 0x20 || character == 0x09 else { break }
				visibleStart -= 1
			}
			let movedWhitespace = text.substring(with: NSRange(
				location: visibleStart, length: word.location - visibleStart))
			range = NSRange(location: visibleStart, length: boundary - visibleStart)
			return AdjacentWordDeletion(
				range: range,
				replacement: preservedSyntax + movedWhitespace)
		}
		var visibleEnd = word.upperBound
		while visibleEnd < text.length {
			let character = text.character(at: visibleEnd)
			guard character == 0x20 || character == 0x09 else { break }
			visibleEnd += 1
		}
		let movedWhitespace = text.substring(with: NSRange(
			location: word.upperBound, length: visibleEnd - word.upperBound))
		range = NSRange(location: boundary, length: visibleEnd - boundary)
		return AdjacentWordDeletion(
			range: range,
			replacement: movedWhitespace + preservedSyntax)
	}

	private static func isInlineDelimiterUnit(_ character: unichar) -> Bool {
		character == 0x2A || character == 0x5F || character == 0x7E ||
		character == 0x3D || character == 0x5E || character == 0x60
	}

	/// Returns hidden closing syntax between a selected visible endpoint and
	/// the following block separator. Besides symmetric delimiters this covers
	/// link destinations and normalized wrapper closers such as `</u>`.
	private static func blockBoundaryHiddenSuffix(
		in selectedSource: NSString,
		visibleEnd: Int
	) -> String? {
		guard visibleEnd >= 0, visibleEnd < selectedSource.length else { return nil }
		var separator = visibleEnd
		while separator < selectedSource.length {
			let character = selectedSource.character(at: separator)
			if character == 0x0A || character == 0x0D { break }
			separator += 1
		}
		guard separator > visibleEnd, separator < selectedSource.length else { return nil }
		let visibleBoundary = visibleWordBoundaryBeforeHiddenInlineSuffix(
			in: selectedSource, boundary: separator)
		if visibleBoundary == visibleEnd {
			return selectedSource.substring(with: NSRange(
				location: visibleEnd, length: separator - visibleEnd))
		}
		var delimiterEnd = visibleEnd
		while delimiterEnd < separator,
		      isInlineDelimiterUnit(selectedSource.character(at: delimiterEnd)) {
			delimiterEnd += 1
		}
		return delimiterEnd > visibleEnd
			? selectedSource.substring(with: NSRange(
				location: visibleEnd, length: delimiterEnd - visibleEnd))
			: nil
	}

	private struct PrivateBoundaryPaste {
		let range: NSRange
		let replacement: String
		let caret: Int
	}

	private static func emptyUnderlineStart(in source: NSString, caret: Int) -> Int? {
		func isEmptyUnderline(at location: Int) -> Bool {
			guard location >= 0, location + 7 <= source.length else { return false }
			return source.substring(with: NSRange(location: location, length: 7))
				.caseInsensitiveCompare("<u></u>") == .orderedSame
		}
		if isEmptyUnderline(at: caret) { return caret }
		if isEmptyUnderline(at: caret - 7) { return caret - 7 }
		if isEmptyUnderline(at: caret - 3) { return caret - 3 }
		return nil
	}

	private static func emptyUnderlineClusterStart(
		in source: NSString,
		caret: Int
	) -> Int? {
		guard var start = emptyUnderlineStart(in: source, caret: caret) else { return nil }
		while start >= 7,
		      source.substring(with: NSRange(location: start - 7, length: 7))
				.caseInsensitiveCompare("<u></u>") == .orderedSame {
			start -= 7
		}
		return start
	}

	/// Reverses a styled block-boundary Cut at an external empty-wrapper home.
	/// Cut preserves the adjacent inline delimiter so the remaining Markdown is
	/// balanced; the private flavor still owns the original delimiter and must
	/// therefore be split around the preserved copy rather than inserted raw.
	private static func privateBoundaryPaste(
		in source: NSString,
		caret: Int,
		pasted: String,
		wrapperStart activeWrapperStart: Int
	) -> PrivateBoundaryPaste? {
		guard emptyUnderlineStart(in: source, caret: caret) != nil,
		      emptyUnderlineStart(in: source, caret: activeWrapperStart) == activeWrapperStart
		else { return nil }
		let wrapperStart = activeWrapperStart
		let pastedText = pasted as NSString
		guard pastedText.length > 1 else { return nil }

		var firstBreak = NSNotFound
		for index in 0..<pastedText.length {
			let character = pastedText.character(at: index)
			if character == 0x0A || character == 0x0D {
				firstBreak = index
				break
			}
		}
		guard firstBreak != NSNotFound else { return nil }
		func lineBreakLength(at index: Int) -> Int {
			guard index >= 0, index < pastedText.length else { return 0 }
			let character = pastedText.character(at: index)
			if character == 0x0A { return 1 }
			if character == 0x0D {
				return index + 1 < pastedText.length &&
					pastedText.character(at: index + 1) == 0x0A ? 2 : 1
			}
			return 0
		}
		var boundaryStart = firstBreak
		var foundBlockSeparator = false
		var scan = firstBreak
		while scan < pastedText.length {
			let firstLength = lineBreakLength(at: scan)
			if firstLength > 0 {
				var second = scan + firstLength
				while second < pastedText.length {
					let character = pastedText.character(at: second)
					guard character == 0x20 || character == 0x09 else { break }
					second += 1
				}
				if lineBreakLength(at: second) > 0 {
					boundaryStart = scan
					foundBlockSeparator = true
				}
				scan += firstLength
			} else {
				scan += 1
			}
		}
		guard foundBlockSeparator else { return nil }

		// Backward selection: visible suffix + closing delimiter + separator.
		if boundaryStart > 0 {
			var delimiterStart = visibleWordBoundaryBeforeHiddenInlineSuffix(
				in: pastedText, boundary: boundaryStart)
			if delimiterStart == boundaryStart {
				while delimiterStart > 0,
				      isInlineDelimiterUnit(pastedText.character(at: delimiterStart - 1)) {
					delimiterStart -= 1
				}
			}
			if delimiterStart > 0, delimiterStart < boundaryStart {
				let delimiter = pastedText.substring(with: NSRange(
					location: delimiterStart, length: boundaryStart - delimiterStart))
				let delimiterLength = (delimiter as NSString).length
				var beforeWrapperCluster = wrapperStart
				while beforeWrapperCluster >= 7,
				      source.substring(with: NSRange(
						location: beforeWrapperCluster - 7, length: 7))
						.caseInsensitiveCompare("<u></u>") == .orderedSame {
					beforeWrapperCluster -= 7
				}
				if beforeWrapperCluster >= delimiterLength,
				   source.substring(with: NSRange(
					location: beforeWrapperCluster - delimiterLength,
					length: delimiterLength)) == delimiter {
					let visible = pastedText.substring(to: delimiterStart)
					let boundary = pastedText.substring(from: boundaryStart)
					let replacement = visible + delimiter + boundary
					let start = beforeWrapperCluster - delimiterLength
					return PrivateBoundaryPaste(
						range: NSRange(location: start, length: delimiterLength),
						replacement: replacement,
						caret: wrapperStart + (replacement as NSString).length - delimiterLength + 3)
				}
			}
			let boundary = pastedText.substring(from: boundaryStart)
			let prefixUnits = CharacterSet(charactersIn: ">-+*#[]xX0123456789.)")
			let prefixMarkers = CharacterSet(charactersIn: ">-+*#[].)")
			let isWhitespaceBoundary = boundary.unicodeScalars.allSatisfy {
				CharacterSet.whitespacesAndNewlines.contains($0)
			}
			let isPrefixedBoundary = boundary.unicodeScalars.allSatisfy {
				CharacterSet.whitespacesAndNewlines.contains($0) || prefixUnits.contains($0)
			} && boundary.unicodeScalars.contains {
				prefixMarkers.contains($0) && !CharacterSet.whitespaces.contains($0)
			}
			if (caret == wrapperStart || caret == wrapperStart + 3),
			   (isWhitespaceBoundary || isPrefixedBoundary) {
				var insertionStart = wrapperStart
				while insertionStart >= 7,
				      source.substring(with: NSRange(
						location: insertionStart - 7, length: 7))
						.caseInsensitiveCompare("<u></u>") == .orderedSame {
					insertionStart -= 7
				}
				return PrivateBoundaryPaste(
					range: NSRange(location: insertionStart, length: 0),
					replacement: pasted,
					caret: wrapperStart + pastedText.length + 3)
			}
		}

		// Forward selection: separator + opening delimiter + visible prefix.
		var contentStart = 0
		while contentStart < pastedText.length {
			let character = pastedText.character(at: contentStart)
			guard character == 0x20 || character == 0x09 ||
			      character == 0x0A || character == 0x0D else { break }
			contentStart += 1
		}
		var delimiterEnd = contentStart
		if contentStart + 3 <= pastedText.length,
		   pastedText.substring(with: NSRange(location: contentStart, length: 3))
			.caseInsensitiveCompare("<u>") == .orderedSame {
			delimiterEnd = contentStart + 3
		} else {
			while delimiterEnd < pastedText.length,
			      isInlineOpeningDelimiterUnit(pastedText.character(at: delimiterEnd)) {
				delimiterEnd += 1
			}
		}
		guard contentStart > 0 else { return nil }
		if delimiterEnd == contentStart {
			let afterWrapper = wrapperStart + 7
			guard (caret == afterWrapper || caret == wrapperStart + 3),
			      contentStart < pastedText.length else { return nil }
			var insertionStart = afterWrapper
			while insertionStart + 7 <= source.length,
			      source.substring(with: NSRange(
					location: insertionStart, length: 7))
					.caseInsensitiveCompare("<u></u>") == .orderedSame {
				insertionStart += 7
			}
			return PrivateBoundaryPaste(
				range: NSRange(location: insertionStart, length: 0),
				replacement: pasted,
				caret: insertionStart + pastedText.length)
		}
		guard delimiterEnd < pastedText.length else { return nil }
		let delimiter = pastedText.substring(with: NSRange(
			location: contentStart, length: delimiterEnd - contentStart))
		let delimiterLength = (delimiter as NSString).length
		var afterWrapperCluster = wrapperStart + 7
		while afterWrapperCluster + 7 <= source.length,
		      source.substring(with: NSRange(
				location: afterWrapperCluster, length: 7))
				.caseInsensitiveCompare("<u></u>") == .orderedSame {
			afterWrapperCluster += 7
		}
		guard afterWrapperCluster + delimiterLength <= source.length,
		      source.substring(with: NSRange(
			location: afterWrapperCluster, length: delimiterLength)) == delimiter else { return nil }
		let boundary = pastedText.substring(to: contentStart)
		let visible = pastedText.substring(from: delimiterEnd)
		let replacement = boundary + delimiter + visible
		return PrivateBoundaryPaste(
			range: NSRange(location: afterWrapperCluster, length: delimiterLength),
			replacement: replacement,
			caret: afterWrapperCluster + (replacement as NSString).length)
	}

	/// Opening inline syntax can begin with link/image brackets in addition to
	/// symmetric emphasis/code delimiters. Keep this broader than
	/// `isInlineDelimiterUnit`: a closing bracket alone is not sufficient to
	/// preserve a link's complete hidden destination during a backward Cut.
	private static func isInlineOpeningDelimiterUnit(_ character: unichar) -> Bool {
		isInlineDelimiterUnit(character) || character == 0x21 || character == 0x5B
	}

	private static func hiddenInlineSuffixToPreserve(
		in text: NSString,
		wordEnd: Int,
		visibleBoundary: Int,
		boundary: Int
	) -> String {
		if visibleBoundary < boundary, visibleBoundary >= wordEnd {
			// A link may contain normalized inner wrappers between the visible
			// word and `]`; preserve those closers along with the destination.
			return text.substring(with: NSRange(
				location: wordEnd, length: boundary - wordEnd))
		}
		var start = boundary
		while start > wordEnd, isInlineDelimiterUnit(text.character(at: start - 1)) {
			start -= 1
		}
		return start < boundary
			? text.substring(with: NSRange(location: start, length: boundary - start))
			: ""
	}

	private static func hiddenInlinePrefixToPreserve(
		in text: NSString,
		boundary: Int,
		wordStart: Int
	) -> String {
		func includingOuterLink(_ start: Int) -> Int {
			// DOM metadata can expose the inner code/emphasis stack but omit the
			// link ancestor, so include its opener after peeling delimiters.
			start > boundary && text.character(at: start - 1) == 0x5B
				? start - 1 : start
		}
		if wordStart >= 3,
		   text.substring(with: NSRange(location: wordStart - 3, length: 3))
			.caseInsensitiveCompare("<u>") == .orderedSame {
			var start = wordStart - 3
			while start > boundary,
			      isInlineDelimiterUnit(text.character(at: start - 1)) {
				start -= 1
			}
			start = includingOuterLink(start)
			return text.substring(with: NSRange(
				location: start, length: wordStart - start))
		}
		if wordStart > boundary, text.character(at: wordStart - 1) == 0x5B {
			var start = wordStart - 1
			while start > boundary,
			      isInlineDelimiterUnit(text.character(at: start - 1)) {
				start -= 1
			}
			return text.substring(with: NSRange(
				location: start, length: wordStart - start))
		}
		var start = wordStart
		while start > boundary, isInlineDelimiterUnit(text.character(at: start - 1)) {
			start -= 1
		}
		start = includingOuterLink(start)
		return start < wordStart
			? text.substring(with: NSRange(location: start, length: wordStart - start))
			: ""
	}

	/// A backward word delete starts from a rendered boundary, but raw source
	/// may place a closing HTML tag or link destination between that boundary
	/// and the visible label. Peel only verified supported suffix shapes before
	/// asking Foundation for the adjacent visible word.
	private static func visibleWordBoundaryBeforeHiddenInlineSuffix(
		in text: NSString,
		boundary: Int
	) -> Int {
		var wrapperBoundary = boundary
		while wrapperBoundary > 0,
		      isInlineDelimiterUnit(text.character(at: wrapperBoundary - 1)) {
			wrapperBoundary -= 1
		}
		if wrapperBoundary >= 4,
		   text.substring(with: NSRange(location: wrapperBoundary - 4, length: 4))
			.caseInsensitiveCompare("</u>") == .orderedSame {
			return wrapperBoundary - 4
		}
		guard wrapperBoundary > 0,
		      text.character(at: wrapperBoundary - 1) == 0x29 else {
			return boundary
		}
		var scan = wrapperBoundary - 1
		var depth = 0
		while scan >= 0 {
			let character = text.character(at: scan)
			var slashCount = 0
			var slash = scan
			while slash > 0, text.character(at: slash - 1) == 0x5C {
				slashCount += 1
				slash -= 1
			}
			if slashCount.isMultiple(of: 2) {
				if character == 0x29 {
					depth += 1
				} else if character == 0x28 {
					depth -= 1
					if depth == 0 {
						let labelEnd = scan - 1
						return labelEnd >= 0 && text.character(at: labelEnd) == 0x5D
							? labelEnd : boundary
					}
				}
			}
			scan -= 1
		}
		return boundary
	}

	private static func visibleWordBoundaryAfterHiddenInlinePrefix(
		in text: NSString,
		boundary: Int
	) -> Int {
		var scan = boundary
		while scan < text.length {
			let character = text.character(at: scan)
			guard character == 0x20 || character == 0x09 else { break }
			scan += 1
		}
		guard 3 <= text.length - scan,
		      text.substring(with: NSRange(location: scan, length: 3))
			.caseInsensitiveCompare("<u>") == .orderedSame else {
			return boundary
		}
		return scan + 3
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
		guard let rev = body["rev"] as? Int else {
			bridgeIncidents.append("appendTableRow without revision")
			resync(caretAt: nil)
			return
		}
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
		let source = currentSource ?? parent.text
		let ns = source as NSString
		guard let at = body["at"] as? Int, let columns = body["columns"] as? Int,
			  columns > 0, at >= 0, at < ns.length else { thaw(); return }
		let tail = NSRange(location: at, length: ns.length - at)
		let newlineAt = ns.range(of: "\n", range: tail).location
		let lineEnd = newlineAt == NSNotFound ? ns.length : newlineAt
		let precedingNewline = ns.range(
			of: "\n", options: .backwards,
			range: NSRange(location: 0, length: at)).location
		let lineStart = precedingNewline == NSNotFound ? 0 : precedingNewline + 1
		// `columns` crosses the page boundary and feeds String(repeating:).
		// Keep the requested allocation proportional to the actual source row:
		// even the most compact Markdown row needs at least one source code unit
		// per cell. A corrupt/stale page message must not be able to manufacture
		// an arbitrarily large replacement from a tiny document.
		guard columns <= lineEnd - lineStart else { thaw(); return }
		let row = "\n|" + String(repeating: "   |", count: columns)
		currentSource = ns.substring(to: lineEnd) + row + ns.substring(from: lineEnd)
		currentRev += 1
		log("appendTableRow columns=\(columns) after line ending \(lineEnd) rev=\(currentRev)")
		// The renderer stamps an empty cell's caret home on its second padding
		// column — lineEnd + "\n|" + one space puts that at lineEnd + 3.
		pendingSelection = NSRange(location: lineEnd + 3, length: 0)
		pendingStructuralTailDelta = (row as NSString).length
		pendingStructuralTailBoundary = lineEnd
		pendingStructuralText = currentSource
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
		pendingStructuralTailDelta = nil
		pendingStructuralTailBoundary = nil
		pendingStructuralText = nil
		lastRenderedText = source
		lastConfigSignature = configSignature()
		bumpEpoch()
		loadHTML(for: source, into: webView)
	}

	private func imageRequest(source: String, altText: String) -> MarkdownImageRequest? {
		guard let url = URL(string: source), let scheme = url.scheme?.lowercased() else { return nil }
		let resolved: URL
		switch scheme {
		case MarkdownWebView.resourceScheme, "file":
			guard let local = localResourceAccessPolicy?.authorizedFileURL(for: url) else { return nil }
			resolved = local
		case "http", "https":
			guard parent.allowsRemoteResources else { return nil }
			resolved = url
		case "data":
			let lower = source.lowercased()
			guard lower.hasPrefix("data:image/"),
			      source.utf8.count <= LocalResourceAccessPolicy.maximumResourceBytes * 2 else { return nil }
			resolved = url
		default:
			return nil
		}
		return MarkdownImageRequest(url: resolved, altText: String(altText.prefix(512)))
	}
}
