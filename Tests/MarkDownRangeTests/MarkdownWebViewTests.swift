import Testing
@testable import MarkDownRange

#if os(macOS)
@Suite struct MarkdownWebViewTests {
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

	@Test @MainActor func editorScriptShiftsStampsAfterInPlaceEdits() {
		let script = MarkdownWebView.Coordinator.editorScript
		#expect(script.contains("function shiftStamps(start, delta, editedSpan)"))
		#expect(script.contains("shift: { start: start, delta: data.length - (end - start), span: startSpan }"))
		#expect(script.contains("if (queued.shift) { shiftStamps(queued.shift.start, queued.shift.delta, queued.shift.span); }"))
	}

	@Test @MainActor func editorScriptQueuesBatchedEdits() {
		// WebKit batches editing commands (typing a quote inserts it AND
		// retroactively curls the previous quote); a single pending slot
		// dropped all but the last edit in the batch.
		let script = MarkdownWebView.Coordinator.editorScript
		#expect(script.contains("var pendingEdits = [];"))
		#expect(script.contains("pendingEdits.push({ msg: { start: start, end: end, text: data"))
		#expect(script.contains("pendingEdits.push({ msg: { start: start, end: end, text: ''"))
		#expect(script.contains("while (pendingEdits.length) {"))
	}

	@Test @MainActor func editorScriptSendsContextAndEscalatesCrossRunEdits() {
		let script = MarkdownWebView.Coordinator.editorScript
		#expect(script.contains("function contextBefore(node, offset)"))
		#expect(script.contains("function contextAfter(node, offset)"))
		#expect(script.contains("var crossRun = startSpan !== spanOf(endPos.node, endPos.offset);"))
		#expect(script.contains("function normalizePosition(node, offset)"))
		#expect(script.contains("crossRun: true"))
	}

	@Test @MainActor func contentSwapsInPlaceWithEditorStateReset() {
		// External text changes update the loaded page via a body swap (no
		// navigation flash); the editor re-arms its per-content state.
		let scrollScript = MarkdownWebView.Coordinator.scrollSyncScript
		#expect(scrollScript.contains("window.__mdSwapContent = function (html)"))
		#expect(scrollScript.contains("if (window.__mdAfterSwap) { window.__mdAfterSwap(); }"))
		let editorScript = MarkdownWebView.Coordinator.editorScript
		#expect(editorScript.contains("window.__mdAfterSwap = function ()"))
		#expect(editorScript.contains("frozen = false;"))
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
		#expect(script.contains("post({ start: c.base, end: c.base + c.beforeText.length, text: after, expected: c.beforeText, before: '', after: '' });"))
		#expect(script.contains("post({ type: 'desync' })"))
	}
}
#endif
