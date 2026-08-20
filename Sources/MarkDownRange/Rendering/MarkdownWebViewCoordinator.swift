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
#else
	import UIKit
#endif
import SwiftUI
import WebKit

extension MarkdownWebView {
	@MainActor
	public final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
		var parent: MarkdownWebView
		weak var webView: WKWebView?
		var localResourceAccessPolicy: LocalResourceAccessPolicy?
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
		/// Newest host-owned source waiting for its debounced render. While this
		/// is non-nil the old page is frozen and its revision epoch is closed:
		/// accepting an edit from that DOM could overwrite newer raw-pane text.
		var pendingHostText: String?
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
		/// Selection-handoff token already applied.
		private var lastSelectionTargetToken: Int?
		/// `initialScrollFraction` is applied only once, after the first render.
		private var didApplyInitialScroll = false
		private var didStartInitialRender = false
		private var didFinishInitialRender = false
		private var didSignalInitialRenderReady = false
		private var initialDocumentNavigation: WKNavigation?
		/// Production views install bridge scripts through WKUserScript at
		/// document-end. The test harness keeps exercising the evaluate path.
		var usesDocumentEndScripts = false
		/// Renders happen off the main actor; each new render bumps this and a
		/// finished render only lands while its generation is still current, so
		/// a slow render of stale text can't overwrite a newer page.
		private var renderGeneration = 0
		/// Currently executing full/fragment render. Superseding work cancels
		/// the task as well as advancing the generation, so cancellable render
		/// stages can stop consuming CPU instead of merely dropping their result.
		var renderTask: Task<Void, Never>?
		var linkPreviewTask: Task<Void, Never>?
		/// Serialize renders for this document without forcing unrelated
		/// windows through one process-wide queue. A huge background document
		/// must not head-of-line block a small edit in the active window.
		let renderService = MarkdownRenderService()
		/// The per-block fragments of the page currently shown — the baseline
		/// incremental patches diff against. Nil until a full render lands.
		var lastFragments: [MarkdownBlockFragment]?
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
		private var openedLinkAccessScopes: [URL] = []

		init(parent: MarkdownWebView) {
			self.parent = parent
		}

		deinit {
			pendingSwap?.cancel()
			renderTask?.cancel()
			linkPreviewTask?.cancel()
			for scope in openedLinkAccessScopes {
				scope.stopAccessingSecurityScopedResource()
			}
		}

		func configSignature() -> String {
			"\(parent.isEditable)|\(parent.onCheckboxToggle != nil)|\(parent.onOpenImage != nil)|\(parent.renderMermaid)|\(parent.allowsRemoteResources)|\(parent.resolvedTheme.signature)|\(parent.fontSize)|\(parent.baseURL?.absoluteString ?? "")|\(parent.contentReloadToken)"
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
			guard parent.text != lastRenderedText || config != lastConfigSignature else {
				// A burst may return to the text the page already shows before
				// its debounced host update lands. Cancel that render and thaw
				// the still-correct DOM at the coordinator's current revision.
				if pendingHostText != nil {
					pendingSwap?.cancel()
					pendingSwap = nil
					pendingHostText = nil
					currentSource = parent.text
					webView.evaluateJavaScript(
						"window.__mdSetRev && window.__mdSetRev(\(currentRev));",
						completionHandler: nil)
				}
				return
			}
			// A full (navigating) load is needed for the first render, for
			// config changes (theme/font mean new CSS), for mermaid pages (the
			// embedded engine script doesn't survive a body swap), and for our
			// own structural edits, whose pending caret is placed in
			// `didFinish`. Everything else — the text changing under us, i.e.
			// typing in the raw pane of a split — updates the page in place
			// after a debounce, so the preview neither flashes through a blank
			// navigation nor re-renders on every keystroke.
			// A structural edit on a page we hold fragments for patches the DOM
			// in place instead of navigating — no blank flash, no full-document
			// re-render, scroll preserved by construction.
			if pendingSelection != nil, config == lastConfigSignature,
			   !(parent.renderMermaid && !parent.isEditable), lastFragments != nil {
				pendingSwap?.cancel()
				pendingSwap = nil
				pendingHostText = nil
				applyStructuralPatch(into: webView)
				return
			}
			if lastRenderedText == nil || pendingSelection != nil || config != lastConfigSignature
				|| (parent.renderMermaid && !parent.isEditable) {
				pendingSwap?.cancel()
				pendingSwap = nil
				pendingHostText = nil
				lastRenderedText = parent.text
				lastConfigSignature = config
				log("reload: textLen=\((parent.text as NSString).length)")
				currentSource = parent.text
				bumpEpoch()
				loadHTML(for: parent.text, into: webView)
				return
			}
			beginHostUpdate(parent.text, in: webView)
			pendingSwap?.cancel()
			pendingSwap = Task { @MainActor [weak self, weak webView] in
				try? await Task.sleep(for: .milliseconds(250))
				guard !Task.isCancelled, let self, let webView else { return }
				self.pendingSwap = nil
				self.applyBodySwap(into: webView)
			}
		}

		/// Close the edit epoch as soon as fresher host text arrives, not after
		/// the debounce and render. The page still projects the old source in
		/// that interval, so it must not accept input based on stale offsets.
		private func beginHostUpdate(_ text: String, in webView: WKWebView) {
			guard pendingHostText != text else { return }
			pendingHostText = text
			currentSource = text
			selfEdit = nil
			renderTask?.cancel()
			renderTask = nil
			renderGeneration += 1
			bumpEpoch()
			webView.evaluateJavaScript(
				"window.__mdBeginHostUpdate && window.__mdBeginHostUpdate();",
				completionHandler: nil)
		}

		/// Re-render the body and swap it into the loaded page in place.
		/// Reads the freshest `parent` state at fire time — later updates may
		/// have arrived during the debounce. The render itself runs off the
		/// main actor; the update lands only if nothing changed underneath it,
		/// and patches just the changed blocks when a baseline exists.
		private func applyBodySwap(into webView: WKWebView) {
			let text = parent.text
			let config = configSignature()
			guard text != lastRenderedText || config != lastConfigSignature else { return }
			guard config == lastConfigSignature, pendingSelection == nil else {
				load(into: webView)   // needs a full load after all
				return
			}
			renderTask?.cancel()
			renderGeneration += 1
			let generation = renderGeneration
			let theme = parent.resolvedTheme
			let fontSize = parent.fontSize
			let includeOffsets = parent.isEditable
			let checkboxes = parent.onCheckboxToggle != nil
			let baseline = lastFragments
			let renderService = renderService
			renderTask = Task { @MainActor [weak self, weak webView] in
				let rendered = await renderService.blockResult(
					markdown: text, theme: theme, fontSize: fontSize,
					includeSourceOffsets: includeOffsets,
					interactiveCheckboxes: checkboxes,
					baseline: baseline)
				// Re-validate: a newer render, a config change, a structural edit,
				// or fresher text supersedes this result.
				guard let self, let webView, !Task.isCancelled,
				      generation == self.renderGeneration, self.configSignature() == config,
				      self.pendingSelection == nil, self.parent.text == text,
				      self.pendingHostText == text else { return }
				self.renderTask = nil
				self.lastRenderedText = text
				self.currentSource = text
				self.pendingHostText = nil
				self.apply(rendered, into: webView, thenPlaceCaret: nil)
			}
		}

		/// A structural edit's re-render: patch the changed blocks in place and
		/// restore the caret/selection; fall back to a full navigation when the
		/// patch can't be computed or the live DOM refuses it.
		private func applyStructuralPatch(into webView: WKWebView) {
			let text = parent.text
			lastRenderedText = text
			// Close the revision epoch NOW, before awaiting the render. Until the
			// patch lands, the page still shows the previous DOM and still
			// declares the previous revision — and a host-driven restore (undo /
			// redo) doesn't freeze the page, so a keystroke in that window would
			// arrive at a *matching* revision and splice into the pre-restore
			// source, handing the undone text straight back. Reseeding here makes
			// those stragglers pre-reseed: dropped, costing one keystroke instead
			// of the undo.
			currentSource = text
			bumpEpoch()
			renderGeneration += 1
			let generation = renderGeneration
			let selection = pendingSelection
			let theme = parent.resolvedTheme
			let fontSize = parent.fontSize
			let includeOffsets = parent.isEditable
			let checkboxes = parent.onCheckboxToggle != nil
			let baseline = lastFragments
			let renderService = renderService
			renderTask?.cancel()
			renderTask = Task { @MainActor [weak self, weak webView] in
				let rendered = await renderService.blockResult(
					markdown: text, theme: theme, fontSize: fontSize,
					includeSourceOffsets: includeOffsets,
					interactiveCheckboxes: checkboxes,
					baseline: baseline)
				guard let self, let webView, generation == self.renderGeneration else { return }
				self.renderTask = nil
				self.pendingSelection = nil
				self.apply(rendered, into: webView, thenPlaceCaret: selection)
			}
		}

		/// Land freshly rendered fragments on the page: patch the changed span
		/// when the baseline allows it, otherwise swap the whole body. Assumes
		/// the caller has already committed coordinator state (text, epoch).
		func apply(_ rendered: MarkdownRenderService.BlockResult, into webView: WKWebView, thenPlaceCaret selection: NSRange?) {
			let fragments = rendered.fragments
			let generation = renderGeneration
			let revision = currentRev
			let fullSwap = { [weak self, weak webView] in
				guard let self, let webView else { return }
				guard generation == self.renderGeneration, revision == self.currentRev else { return }
				let renderService = self.renderService
				self.renderTask = Task { @MainActor [weak self, weak webView] in
					let bodyJSON: String
					if let prepared = rendered.bodyJSON {
						bodyJSON = prepared
					} else {
						guard let generated = await renderService.bodyJSON(for: fragments)
						else { return }
						bodyJSON = generated
					}
					guard let self, let webView,
					      generation == self.renderGeneration,
					      revision == self.currentRev else { return }
					self.renderTask = nil
					self.log("body swap: \(fragments.count) blocks rev=\(revision)")
					do {
						_ = try await webView.evaluateJavaScript(
							"window.__mdSwapContent && window.__mdSwapContent(\(bodyJSON), \(revision));")
					} catch {
						return
					}
					guard generation == self.renderGeneration,
					      revision == self.currentRev else { return }
					self.lastFragments = fragments
					self.placeCaretAfterUpdate(selection, into: webView)
					self.applyLineChanges(to: webView, force: true)
				}
			}
			guard let patch = rendered.patch,
			      let htmlJSON = rendered.patchHTMLJSON else {
				fullSwap()
				return
			}
			log("patch: \(patch.removeCount)→\(patch.html.count) blocks at \(patch.start), tail anchor \(patch.tailAnchorOffset)@\(patch.tailAnchorStamp), rev \(revision)")
			let call = "window.__mdPatchBlocks ? window.__mdPatchBlocks(\(patch.start), \(patch.removeCount), \(htmlJSON), \(patch.tailAnchorOffset), \(patch.tailAnchorStamp), \(patch.expectedOldCount), \(revision)) : false"
			webView.evaluateJavaScript(call) { [weak self, weak webView] result, error in
				guard let self, let webView else { return }
				guard generation == self.renderGeneration, revision == self.currentRev else { return }
				if (result as? Bool) == true, error == nil {
					self.lastFragments = fragments
					self.placeCaretAfterUpdate(selection, into: webView)
					self.applyLineChanges(to: webView, force: true)
				} else {
					self.log("patch refused by page — full swap fallback")
					fullSwap()
				}
			}
		}

		private func placeCaretAfterUpdate(_ selection: NSRange?, into webView: WKWebView) {
			guard let selection else { return }
			webView.evaluateJavaScript(
				"window.__mdPlaceCaret && window.__mdPlaceCaret(\(caretPlacementArguments(selection)));",
				completionHandler: nil)
		}

		/// Source-line bounds let the page distinguish a caret in hidden Markdown
		/// syntax from one in a genuinely empty paragraph. The former snaps to a
		/// real run on this line; only the latter synthesizes an empty caret home.
		private func caretPlacementArguments(_ selection: NSRange) -> String {
			guard selection.length == 0 else {
				return "\(selection.location), \(selection.length), null, null, false, null"
			}
			let source = (currentSource ?? parent.text) as NSString
			let offset = min(max(0, selection.location), source.length)
			var lineStart = offset
			while lineStart > 0 {
				let character = source.character(at: lineStart - 1)
				if character == 0x0A || character == 0x0D { break }
				lineStart -= 1
			}
			var lineEnd = offset
			while lineEnd < source.length {
				let character = source.character(at: lineEnd)
				if character == 0x0A || character == 0x0D { break }
				lineEnd += 1
			}
			let snapHiddenSyntax: Bool
			if offset < source.length {
				let character = source.character(at: offset)
				snapHiddenSyntax = character != 0x09 && character != 0x0A &&
					character != 0x0D && character != 0x20
			} else {
				snapHiddenSyntax = false
			}
			let visualBlankOffset = visualBlankOffsetBeforeCaret(in: source, at: offset)
				.map(String.init) ?? "null"
			return "\(offset), 0, \(lineStart), \(lineEnd), \(snapHiddenSyntax), \(visualBlankOffset)"
		}

		/// Markdown collapses blank source lines, but Return at a block start has
		/// just created one the editor must keep visible. Identify the source
		/// position of that empty row so the page can install a temporary stamped
		/// spacer while keeping the caret in the moved block below it.
		private func visualBlankOffsetBeforeCaret(in source: NSString, at offset: Int) -> Int? {
			var cursor = offset
			guard consumeLineBreakBackward(in: source, cursor: &cursor),
				  consumeLineBreakBackward(in: source, cursor: &cursor) else { return nil }
			let blankOffset = cursor
			if cursor == 0 { return blankOffset }
			guard consumeLineBreakBackward(in: source, cursor: &cursor),
				  consumeLineBreakBackward(in: source, cursor: &cursor) else { return nil }
			return blankOffset
		}

		private func consumeLineBreakBackward(in source: NSString, cursor: inout Int) -> Bool {
			guard cursor > 0 else { return false }
			let character = source.character(at: cursor - 1)
			if character == 0x0A {
				cursor -= 1
				if cursor > 0, source.character(at: cursor - 1) == 0x0D { cursor -= 1 }
				return true
			}
			guard character == 0x0D else { return false }
			cursor -= 1
			return true
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
			let isInitialRender = !didStartInitialRender
			startInitialRenderIfNeeded()
			renderTask?.cancel()
			renderGeneration += 1
			let generation = renderGeneration
			let theme = parent.resolvedTheme
			let fontSize = parent.fontSize
			let includeOffsets = parent.isEditable
			let checkboxes = parent.onCheckboxToggle != nil
			let allowRemoteResources = parent.allowsRemoteResources
			// Render mermaid as diagrams when the host opted in and we're not
			// editing (editing keeps the raw, editable source). The engine
			// loads through our scheme handler instead of being inlined.
			let embedMermaid = parent.renderMermaid && !parent.isEditable
			let preparedRender = isInitialRender ? parent.preparedInitialRender : nil
			let preparedConfiguration = MarkdownPreparedWebRender.Configuration(
				markdown: text,
				theme: theme,
				fontSize: fontSize,
				includeSourceOffsets: includeOffsets,
				interactiveCheckboxes: checkboxes,
				embedMermaidEngine: embedMermaid,
				allowRemoteResources: allowRemoteResources)
			let baseURL = resourceBaseURL(for: parent.baseURL) ?? parent.baseURL
			if let rendered = preparedRender?.completedResult(matching: preparedConfiguration) {
				lastFragments = rendered.fragments
				reportInitialRenderProgress(0.25)
				initialDocumentNavigation = webView.loadHTMLString(rendered.html, baseURL: baseURL)
				return
			}
			let renderService = renderService
			renderTask = Task { @MainActor [weak self, weak webView] in
				let rendered: MarkdownRenderService.DocumentHTML
				if let prepared = await preparedRender?.result(matching: preparedConfiguration) {
					rendered = prepared
				} else {
					rendered = await renderService.documentHTML(
						markdown: text, theme: theme, fontSize: fontSize,
						includeSourceOffsets: includeOffsets, interactiveCheckboxes: checkboxes,
						embedMermaidEngine: embedMermaid,
						allowRemoteResources: allowRemoteResources)
				}
				guard !Task.isCancelled, let self, let webView,
				      generation == self.renderGeneration else { return }
				self.renderTask = nil
				self.lastFragments = rendered.fragments
				self.reportInitialRenderProgress(0.25)
				// Load under the custom resource scheme (when we have a document
				// folder) so relative <img> paths resolve to the scheme handler,
				// which can actually read local files — WKWebView won't load
				// file:// subresources of an loadHTMLString page.
				self.initialDocumentNavigation = webView.loadHTMLString(rendered.html, baseURL: baseURL)
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

		public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
			guard navigation === initialDocumentNavigation else { return }
			reportInitialRenderProgress(0.75)
		}

		public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
			completePageSetup(in: webView)
		}

		func completePageSetup(in webView: WKWebView) {
			guard isTrustedDocumentURL(webView.url) else {
				log("refusing script injection into untrusted navigation \(webView.url?.absoluteString ?? "nil")")
				return
			}
			if !usesDocumentEndScripts {
				if parent.onCheckboxToggle != nil {
					webView.evaluateJavaScript(Self.checkboxScript, completionHandler: nil)
				}
				webView.evaluateJavaScript(Self.imagePresentationScript, completionHandler: nil)
				// Always install scroll reporting / control, even for a read-only
				// preview, so a host can sync its scroll position to this view.
				webView.evaluateJavaScript(Self.scrollSyncScript, completionHandler: nil)
			}
			let imagePresentationEnabled = parent.onOpenImage != nil ? "true" : "false"
			webView.evaluateJavaScript(
				"window.__mdSetImagePresentationEnabled && window.__mdSetImagePresentationEnabled(\(imagePresentationEnabled));"
			) { [weak self] _, error in
				if let error { self?.log("image presentation setup failed: \(error)") }
				else { self?.log("image presentation enabled: \(imagePresentationEnabled)") }
			}
			applyLineChanges(to: webView, force: true)
			if parent.isEditable {
				if !usesDocumentEndScripts {
					webView.evaluateJavaScript(Self.editorScript, completionHandler: nil)
				}
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
				webView.evaluateJavaScript(
					"window.__mdRestoreScrollThenCaret && window.__mdRestoreScrollThenCaret(\(lastScrollY), \(caretPlacementArguments(selection)));",
					completionHandler: nil)
			} else if !didApplyInitialScroll, let initial = parent.initialScrollFraction {
				didApplyInitialScroll = true
				log("didFinish: initial scroll fraction \(initial)")
				webView.evaluateJavaScript("window.__mdScrollToFraction && window.__mdScrollToFraction(\(initial));", completionHandler: nil)
			} else if lastScrollY > 0 {
				log("didFinish: restoring scrollY \(lastScrollY)")
				webView.evaluateJavaScript("window.__mdRestoreScrollThenCaret && window.__mdRestoreScrollThenCaret(\(lastScrollY), null, 0);", completionHandler: nil)
			}
			if didStartInitialRender, !didSignalInitialRenderReady {
				didSignalInitialRenderReady = true
				parent.onInitialRenderReady?()
			}
			finishInitialRenderIfNeeded()
		}

		public func webView(
			_ webView: WKWebView,
			didFail navigation: WKNavigation!,
			withError error: any Error
		) {
			finishInitialRenderIfNeeded()
		}

		public func webView(
			_ webView: WKWebView,
			didFailProvisionalNavigation navigation: WKNavigation!,
			withError error: any Error
		) {
			finishInitialRenderIfNeeded()
		}

		private func startInitialRenderIfNeeded() {
			guard !didStartInitialRender else { return }
			didStartInitialRender = true
			parent.onInitialRenderProgress?(0)
		}

		private func finishInitialRenderIfNeeded() {
			guard didStartInitialRender, !didFinishInitialRender else { return }
			didFinishInitialRender = true
			parent.onInitialRenderProgress?(nil)
		}

		private func reportInitialRenderProgress(_ progress: Double) {
			guard didStartInitialRender, !didFinishInitialRender else { return }
			parent.onInitialRenderProgress?(progress)
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

		/// Install a selection handed off by another editor mode. A newly
		/// mounted web view keeps it pending until its first stamped render;
		/// an already-rendered view can apply it immediately.
		func applySelectionTarget(to webView: WKWebView) {
			guard let target = parent.selectionTarget,
			      target.token != lastSelectionTargetToken else { return }
			lastSelectionTargetToken = target.token
			let sourceLength = (parent.text as NSString).length
			let location = min(max(0, target.range.location), sourceLength)
			let length = min(max(0, target.range.length), sourceLength - location)
			let selection = NSRange(location: location, length: length)
			if currentSource == parent.text {
				placeCaretAfterUpdate(selection, into: webView)
			} else {
				pendingSelection = selection
			}
			selfEdit = nil
		}

		/// True when this web view (or a descendant, e.g. the WKContentView) holds
		/// the window's first responder — i.e. it's the editor the user is in.
		private var isFirstResponder: Bool {
			guard let webView else { return false }
			#if os(macOS)
				guard let responder = webView.window?.firstResponder as? NSView else { return false }
				return responder === webView || responder.isDescendant(of: webView)
			#else
				// UIKit has no window-wide first-responder accessor; the web
				// view reports its own focus, and WKContentView's editing
				// focus surfaces through it.
				return webView.isFirstResponder
					|| webView.subviews.contains { $0.isFirstResponder }
			#endif
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

		public func webView(
			_ webView: WKWebView,
			decidePolicyFor navigationAction: WKNavigationAction,
			decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
		) {
			let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
			guard isMainFrame else {
				decisionHandler(.cancel)
				return
			}
			guard let url = navigationAction.request.url else {
				decisionHandler(.cancel)
				return
			}
			if navigationAction.navigationType == .other, isTrustedDocumentURL(url) {
				decisionHandler(.allow)
				return
			}
			if navigationAction.navigationType == .linkActivated,
			   isInPageAnchor(url, base: webView.url) {
				decisionHandler(.allow)
				return
			}
			decisionHandler(.cancel)
			if navigationAction.navigationType == .linkActivated {
				open(url)
			} else {
				log("blocked top-level navigation type=\(navigationAction.navigationType.rawValue) url=\(url.absoluteString)")
			}
		}

		func isTrustedDocumentURL(_ url: URL?) -> Bool {
			guard let url else { return false }
			if url.scheme == "about" { return url.absoluteString == "about:blank" }
			return url.scheme == MarkdownWebView.resourceScheme && url.host == "res"
		}

		private func isInPageAnchor(_ url: URL, base: URL?) -> Bool {
			guard url.fragment != nil else { return false }
			guard let base else { return url.scheme == "about" }
			var target = URLComponents(url: url, resolvingAgainstBaseURL: true)
			var current = URLComponents(url: base, resolvingAgainstBaseURL: true)
			target?.fragment = nil
			current?.fragment = nil
			return target == current
		}

		func open(_ url: URL) {
			// Links resolve against the custom resource-scheme base; map them back
			// to real file URLs before opening.
			let resolved = url.scheme == MarkdownWebView.resourceScheme ? URL(fileURLWithPath: url.path) : url
			let isMarkdown = resolved.isFileURL
				&& Self.markdownExtensions.contains(resolved.pathExtension.lowercased())
			guard isMarkdown, !isReadable(resolved) else {
				parent.linkHandler.openLink(resolved, isMarkdownDocument: isMarkdown)
				return
			}
			// A markdown link the sandbox can't read yet: ask for access first,
			// and hold any scope the host started so the page keeps working.
			if let scoped = parent.linkHandler.requestAccess(to: resolved, scope: parent.linkAccessScope) {
				openedLinkAccessScopes.append(scoped)
			}
		}

		private func isReadable(_ url: URL) -> Bool {
			FileManager.default.isReadableFile(atPath: url.path)
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
