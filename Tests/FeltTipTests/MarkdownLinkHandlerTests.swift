#if os(macOS)
import Foundation
import Testing
@testable import FeltTip

@Suite("Default Markdown link handler")
struct MarkdownLinkHandlerTests {
	@Test("A stalled granted-path resolution times out")
	func stalledResolutionTimesOut() {
		let gate = DispatchSemaphore(value: 0)
		let selected = URL(filePath: "/Volumes/disconnected")
		let target = selected.appending(path: "note.md")

		let paths = DefaultMarkdownLinkHandler.resolveAccessPaths(
			selected: selected,
			target: target,
			timeout: .milliseconds(20)) { url in
				_ = gate.wait(timeout: .now() + 10)
				return url
			}
		gate.signal()

		#expect(paths == nil)
	}

	@Test("Readable grant paths are preserved")
	func resolvesPaths() {
		let selected = URL(filePath: "/tmp/felttip-grant")
		let target = selected.appending(path: "note.md")
		let paths = DefaultMarkdownLinkHandler.resolveAccessPaths(
			selected: selected,
			target: target)

		#expect(paths?.chosen == selected)
		#expect(paths?.wanted == target)
	}
}
#endif
