import Foundation
import Testing
@testable import FeltTip

@Suite("Markdown content")
struct MarkdownContentTests {
	@Test("A stalled URL read times out")
	func stalledURLReadTimesOut() {
		let gate = DispatchSemaphore(value: 0)
		let url = URL(filePath: "/Volumes/disconnected/document.md")

		let source = url.resolveMarkdown(timeout: .milliseconds(20)) { _ in
			_ = gate.wait(timeout: .now() + 10)
			return "unexpected"
		}
		gate.signal()

		#expect(source.isEmpty)
	}

	@Test("A readable URL preserves its source")
	func readsURL() throws {
		let url = FileManager.default.temporaryDirectory
			.appending(path: "felttip-markdown-content-\(UUID().uuidString).md")
		defer { try? FileManager.default.removeItem(at: url) }
		try "# Loaded".write(to: url, atomically: true, encoding: .utf8)

		#expect(url.resolveMarkdown() == "# Loaded")
	}
}
