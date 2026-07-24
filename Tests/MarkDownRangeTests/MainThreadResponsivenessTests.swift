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
		// Heartbeat on the main actor. If the render ran synchronously on the
		// main thread (the old behavior), the main actor would be blocked for
		// the render's whole duration and the heartbeat could not tick even
		// once before the await returns. Ticks-during-render is the
		// discriminating signal; it stays valid under parallel test load,
		// where wall-clock gap thresholds just measure CPU contention.
		let heartbeat = Task { @MainActor () -> Int in
			var ticks = 0
			while !Task.isCancelled {
				try? await Task.sleep(for: .milliseconds(1))
				ticks += 1
			}
			return ticks
		}
		let html = await MarkdownRenderService.shared.documentHTML(
			markdown: doc, theme: .default, fontSize: 16,
			includeSourceOffsets: true, interactiveCheckboxes: false,
			embedMermaidEngine: false)
		heartbeat.cancel()
		let ticks = await heartbeat.value
		#expect(html.contains("Section 2000"))
		#expect(ticks >= 3, "main actor only ticked \(ticks)× during a background render — was it blocked?")
	}
}
