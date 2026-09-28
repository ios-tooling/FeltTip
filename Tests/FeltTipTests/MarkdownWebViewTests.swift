import Testing
@testable import FeltTip

@Suite struct MarkdownWebViewTests {
	@Test @MainActor func imagePresentationScriptAddsAccessibleControlsAndPinchGesture() {
		let script = MarkdownWebView.Coordinator.imagePresentationScript
		#expect(script.contains("md-image-open-button"))
		#expect(script.contains("Open image in zoomable window"))
		#expect(script.contains("type: 'openImage'"))
		#expect(script.contains("gesturestart"))
		#expect(script.contains("gesturechange"))
		#expect(script.contains("event.scale >= 1.2"))
		#expect(script.contains("rect.width >= 320"))
		#expect(script.contains("rect.height >= 240"))
	}

	@Test @MainActor func imagePresentationIsExplicitlyOptedIn() {
		let plain = MarkdownWebView(text: "", theme: .default, fontSize: 16)
		#expect(plain.onOpenImage == nil)

		let interactive = plain.onOpenImage { _ in }
		#expect(interactive.onOpenImage != nil)
		#expect(plain.makeCoordinator().configSignature() != interactive.makeCoordinator().configSignature())
	}

	@Test @MainActor func linkPreviewScriptTargetsOnlyLocalMarkdown() {
		let script = MarkdownWebView.Coordinator.linkPreviewScript
		#expect(script.contains("type: 'previewLink'"))
		#expect(script.contains("url.protocol !== 'markerlocalres:' && url.protocol !== 'file:'"))
		#expect(script.contains("window.__mdShowLinkPreview"))
		#expect(script.contains("model.pairs.slice(0, 8)"))
		#expect(!script.contains("{{MARKDOWN_EXTENSIONS}}"))
		for ext in MarkdownLinkExtensions.all {
			#expect(script.contains("\"\(ext)\""))
		}
	}

	@Test @MainActor func editorScriptAddsOpenButtonsForLinks() {
		let script = MarkdownWebView.Coordinator.editorScript
		#expect(script.contains("installLinkOpenButtons();"))
		#expect(script.contains("md-link-open-button"))
		#expect(script.contains("post({ type: 'openLink'"))
		#expect(script.contains("button.setAttribute('data-href', link.href);"))
		#expect(script.contains("var displayHref = link.href;"))
		#expect(script.contains("button.title = displayHref;"))
		#expect(script.contains("link.title = displayHref;"))
	}

	@Test @MainActor func localResourceTooltipsUseAuthoredRelativePath() {
		let script = MarkdownWebView.Coordinator.editorScript
		#expect(script.contains("if (link.href.indexOf('markerlocalres://') === 0)"))
		#expect(script.contains("displayHref = link.getAttribute('href') || link.href;"))
		#expect(script.contains("link.title = displayHref;"))
		#expect(script.contains("button.title = displayHref;"))
		#expect(script.contains("button.setAttribute('data-href', link.href);"))
	}

	@Test @MainActor func linkButtonsAreInsertedOutsideSourceOffsetRuns() {
		let script = MarkdownWebView.Coordinator.editorScript
		#expect(script.contains("var sourceRun = link.closest('[data-s]');"))
		#expect(script.contains("if (sourceRun && sourceRun.parentNode) { target = sourceRun; }"))
		#expect(script.contains("target.insertAdjacentElement('afterend', button);"))
	}

	@Test @MainActor func editorScriptShiftsStampsEagerlyWhenQueueing() {
		// Stamps must shift when the edit is QUEUED, not at the input drain:
		// later commands in a batched WebKit turn read their span bases during
		// their own beforeinput, and stale bases put the batch's later edits at
		// the wrong source offsets.
		let script = MarkdownWebView.Coordinator.editorScript
		#expect(script.contains("function shiftStamps(start, delta, editedSpan)"))
		#expect(script.contains("function queueFastEdit(msg, start, delta, span)"))
		#expect(script.contains("shiftStamps(start, delta, span);"))
		#expect(script.contains("stampRev += 1;"))
	}

	@Test @MainActor func editorScriptQueuesBatchedEdits() {
		// WebKit batches editing commands (typing a quote inserts it AND
		// retroactively curls the previous quote); a single pending slot
		// dropped all but the last edit in the batch.
		let script = MarkdownWebView.Coordinator.editorScript
		#expect(script.contains("var pendingEdits = [];"))
		#expect(script.contains("queueFastEdit({ start: start, end: end, text: data"))
		#expect(script.contains("queueFastEdit({ op: type === 'deleteByCut' ? 'cut' : undefined"))
		#expect(script.contains("while (pendingEdits.length) {"))
	}

	@Test @MainActor func editorScriptDeclaresRevisionOnEveryEdit() {
		// Every edit message declares the source revision its offsets address
		// (rev) and a monotonic seq; the host applies only exact rev matches.
		let script = MarkdownWebView.Coordinator.editorScript
		#expect(script.contains("var stampRev = 0;"))
		#expect(script.contains("window.__mdSetRev = function (rev)"))
		#expect(script.contains("msg.rev = stampRev;"))
		#expect(script.contains("msg.seq = seq++;"))
		#expect(script.contains("rev: stampRev, seq: seq++"))
	}

	@Test @MainActor func editorScriptFreezesWithTimeoutSafetyNet() {
		// A structural edit freezes input until the host re-renders; if that
		// re-render never comes, the armed deadline posts frozenTimeout so the
		// host resyncs — typing can never stay silently dead.
		let script = MarkdownWebView.Coordinator.editorScript
		#expect(script.contains("function freeze() {"))
		#expect(script.contains("frozen = { token: token };"))
		#expect(script.contains("post({ type: 'frozenTimeout', token: token })"))
	}

	@Test @MainActor func editorScriptSendsContextAndEscalatesCrossRunEdits() {
		let script = MarkdownWebView.Coordinator.editorScript
		#expect(script.contains("function contextBefore(node, offset)"))
		#expect(script.contains("function contextAfter(node, offset)"))
		#expect(script.contains("var crossRun = startSpan !== spanOf(endPos.node, endPos.offset);"))
		#expect(script.contains("function normalizePosition(node, offset, preferForward)"))
		#expect(script.contains("normalizePosition(range.startContainer, range.startOffset, true)"))
		#expect(script.contains("normalizePosition(range.endContainer, range.endOffset, range.collapsed)"))
		#expect(script.contains("function needsStructuralInlineRefresh(range, replacement, before, after)"))
		#expect(script.contains("crossRun: crossRun"))
	}

	@Test @MainActor func contentSwapsInPlaceWithEditorStateReset() {
		// External text changes update the loaded page via a body swap (no
		// navigation flash); the editor re-arms its per-content state.
		let scrollScript = MarkdownWebView.Coordinator.scrollSyncScript
		#expect(scrollScript.contains("window.__mdSwapContent = function (html, rev)"))
		#expect(scrollScript.contains("if (window.__mdAfterSwap) { window.__mdAfterSwap(rev); }"))
		let editorScript = MarkdownWebView.Coordinator.editorScript
		#expect(editorScript.contains("window.__mdAfterSwap = function (rev)"))
		#expect(editorScript.contains("frozen = null;"))
		#expect(editorScript.contains("if (typeof rev === 'number') { stampRev = rev; }"))
		#expect(editorScript.contains("installLinkOpenButtons();"))
	}

	@Test @MainActor func editorScriptReconcilesCompositionInput() {
		let script = MarkdownWebView.Coordinator.editorScript
		#expect(script.contains("addEventListener('compositionstart'"))
		#expect(script.contains("addEventListener('compositionend'"))
		// While composing, NO event is offset-mapped — marked text (inline
		// predictions, IME) taints the DOM offsets even for plain inserts.
		#expect(script.contains("if (composing || e.isComposing || e.inputType === 'insertCompositionText' || e.inputType === 'deleteCompositionText') return;"))
		// Reconciliation replaces the whole run, verified by its prior text.
		#expect(script.contains("beforeText: plain(span.textContent)"))
		#expect(script.contains("caret: c.base + after.length"))
		#expect(script.contains("Always reconcile the verified whole run structurally"))
		#expect(script.contains("post({ type: 'desync' })"))
	}

	@Test @MainActor func onlySharedScrollScriptReportsScrollEvents() {
		let editor = MarkdownWebView.Coordinator.editorScript
		let scroll = MarkdownWebView.Coordinator.scrollSyncScript
		#expect(!editor.contains("addEventListener('scroll'"))
		#expect(scroll.contains("addEventListener('scroll'"))
		#expect(scroll.contains("requestAnimationFrame"))
		#expect(scroll.contains("type: 'scroll'"))
	}

	@Test @MainActor func scrollScriptCachesAndInvalidatesDocumentDimensions() {
		let script = MarkdownWebView.Coordinator.scrollSyncScript
		#expect(script.contains("var dimensions = null"))
		#expect(script.contains("function scrollDimensions()"))
		#expect(script.contains("new ResizeObserver(invalidateDimensions)"))
		#expect(script.contains("window.addEventListener('resize', invalidateDimensions"))
		#expect(script.components(separatedBy: "invalidateDimensions();").count >= 3)
	}
}
