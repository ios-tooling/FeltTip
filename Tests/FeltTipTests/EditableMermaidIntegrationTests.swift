import Testing
@testable import FeltTip

@Suite(.serialized) @MainActor struct EditableMermaidIntegrationTests {
	@Test func optedInMermaidRendersWhileSurroundingProseRemainsEditable() async throws {
		#expect(MermaidResources.engineJS != nil)
		let harness = try await CoordinatorBridgeHarness(
			source: "Before\n\n```mermaid\nflowchart LR\n  A --> B\n```\n\nAfter",
			renderMermaid: true)

		try await harness.waitUntil("rendered Mermaid diagram") {
			try await harness.evaluate(
				"document.querySelector('.mermaid svg') ? 'yes' : 'no'") == "yes"
		}
		#expect(try await harness.evaluate(
			"document.querySelector('.mermaid')?.contentEditable || ''") == "false")

		try await harness.run("window.__mdPlaceCaret(6); document.execCommand('insertText', false, '!');")
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		#expect(harness.source.hasPrefix("Before!"))
		#expect(try await harness.evaluate(
			"document.querySelector('.mermaid svg') ? 'yes' : 'no'") == "yes")

		try await harness.replaceExternally(harness.source.replacingOccurrences(
			of: "After", with: "Afterwards"))
		try await harness.waitQuiescent()
		try await harness.waitUntil("Mermaid diagram after body swap") {
			try await harness.evaluate(
				"document.querySelector('.mermaid svg') ? 'yes' : 'no'") == "yes"
		}
		#expect(try await harness.evaluate(
			"document.querySelector('.language-mermaid') ? 'yes' : 'no'") == "no")
	}
}
