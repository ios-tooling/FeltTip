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
}
#endif
