//
//  MainThreadResponsivenessTests.swift
//  MarkDownRangeTests
//
//  The gate for off-main rendering: a full-document render of a large file
//  used to run synchronously on the main thread (hundreds of milliseconds of
//  frozen UI per structural edit / preview refresh). With MarkdownRenderService
//  the main actor must stay responsive for the whole render.
//

import Testing
@testable import MarkDownRange

@Suite struct MainThreadResponsivenessTests {
	@Test @MainActor func renderingLargeDocumentDoesNotBlockTheMainActor() async throws {
		var doc = ""
		for i in 1...2000 {
			doc += "# Section \(i)\n\nParagraph \(i) with **bold**, `code`, and a [link](https://example.com/\(i)).\n\n- one\n- two\n\n"
		}
		// Heartbeat on the main actor: it must keep ticking while the render
		// runs; the largest gap between ticks is how long the main thread was
		// stalled.
		let heartbeat = Task { @MainActor () -> Duration in
			var maxGap: Duration = .zero
			var last = ContinuousClock.now
			while !Task.isCancelled {
				try? await Task.sleep(for: .milliseconds(1))
				let now = ContinuousClock.now
				let gap = now - last
				if gap > maxGap { maxGap = gap }
				last = now
			}
			return maxGap
		}
		let html = await MarkdownRenderService.shared.documentHTML(
			markdown: doc, theme: .default, fontSize: 16,
			includeSourceOffsets: true, interactiveCheckboxes: false,
			embedMermaidEngine: false)
		heartbeat.cancel()
		let maxGap = await heartbeat.value
		#expect(html.contains("Section 2000"))
		#expect(maxGap < .milliseconds(50), "main actor stalled \(maxGap) during a background render")
	}
}
