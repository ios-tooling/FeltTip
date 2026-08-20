//
//  EditBridgeUntrustedDocumentTests.swift
//  MarkDownRangeTests
//
//  The end of the threat model, checked in a live page: opening a document that
//  contains script must not run it. The styled view's page hosts the edit
//  bridge, so a script there could rewrite the user's document, read the
//  clipboard through the paste path, or reach the network — the sanitizer is
//  what stands between an untrusted .md file and all of that.
//

import Testing
@testable import MarkDownRange

@Suite(.serialized) @MainActor struct EditBridgeUntrustedDocumentTests {
	@Test func aScriptInTheDocumentNeverRuns() async throws {
		let harness = try await CoordinatorBridgeHarness(
			source: "text\n\n<script>window.__pwned = 'yes'</script>\n\nmore\n")
		try await harness.waitQuiescent()
		#expect(try await harness.evaluate("typeof window.__pwned") == "undefined")
		#expect(try await harness.evaluate("String(document.querySelectorAll('script').length)") == "0")
	}

	@Test func anImageErrorHandlerInTheDocumentNeverRuns() async throws {
		// onerror fires on its own, with no user interaction at all — the
		// nastiest of the handler vectors. Wrapped in a div so it stays an HTML
		// block: a bare <img> line is parsed into an image block and re-rendered
		// from its own attributes, which drops handlers on the way through.
		let harness = try await CoordinatorBridgeHarness(
			source: "text\n\n<div><img src=\"does-not-exist.png\" onerror=\"window.__pwned = 'yes'\"></div>\n")
		try await harness.waitQuiescent()
		try await Task.sleep(for: .milliseconds(300))
		#expect(try await harness.evaluate("typeof window.__pwned") == "undefined")
		#expect(try await harness.evaluate("String(document.querySelectorAll('img').length)") == "1")
	}

	@Test func aScriptArrivingByBodySwapNeverRuns() async throws {
		// The external-change path (typing in the other pane of a split)
		// re-renders through the same fragments. Assigning innerHTML wouldn't
		// execute a <script> even unsanitized, so this guards the swap path
		// against ever being reimplemented in a way that does.
		let harness = try await CoordinatorBridgeHarness(source: "text\n")
		try await harness.replaceExternally("text\n\n<script>window.__pwned = 'yes'</script>\n")
		try await harness.waitQuiescent()
		#expect(try await harness.evaluate("typeof window.__pwned") == "undefined")
		#expect(try await harness.evaluate("String(document.querySelectorAll('script').length)") == "0")
	}

	@Test func editingStillWorksInADocumentThatContainedScript() async throws {
		// Sanitizing removes DOM the source still has, so the stamps around it
		// have to keep addressing the right offsets.
		let source = "alpha\n\n<script>window.__pwned = 1</script>\n\nbeta\n"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.type("X", at: (source as NSString).range(of: "beta").location)
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "alpha\n\n<script>window.__pwned = 1</script>\n\nXbeta\n")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.hardRejections == 0)
		#expect(try await harness.evaluate("typeof window.__pwned") == "undefined")
	}

	@Test func harmlessHTMLInTheDocumentStillRenders() async throws {
		let harness = try await CoordinatorBridgeHarness(
			source: "text\n\n<div class=\"note\"><b>kept</b></div>\n")
		try await harness.waitQuiescent()
		#expect(try await harness.evaluate("String(document.querySelectorAll('div.note').length)") == "1")
		#expect(try await harness.evaluate("document.querySelector('div.note').textContent") == "kept")
	}

	@Test func formControlsCannotSurviveOrNavigateTheEditor() async throws {
		let harness = try await CoordinatorBridgeHarness(
			source: """
			before

			<form action="https://example.com/escape"><button>Continue</button></form>

			after
			""")
		try await harness.waitQuiescent()
		#expect(try await harness.evaluate("String(document.querySelectorAll('form,input,button').length)") == "0")
		#expect(try await harness.evaluate("document.body.textContent.includes('Continue') ? 'yes' : 'no'") == "yes")
		#expect(harness.coordinator.isTrustedDocumentURL(harness.webView.url))
	}

	@Test func programmaticRemoteTopLevelNavigationIsBlocked() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "trusted body\n")
		let originalURL = harness.webView.url
		harness.webView.load(URLRequest(url: try #require(URL(string: "https://example.com/escape"))))
		try await Task.sleep(for: .milliseconds(200))
		#expect(harness.webView.url == originalURL)
		#expect(try await harness.evaluate("document.body.textContent.includes('trusted body') ? 'yes' : 'no'") == "yes")
	}
}
