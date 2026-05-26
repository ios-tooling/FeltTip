#if os(macOS)
import Testing
import Foundation
import AppKit
@testable import MarkDownRange

@Suite @MainActor struct MarkdownTextViewAsyncRenderTests {
	/// Builds a chunk of markdown big enough that a synchronous parse + attachment
	/// build would noticeably block the main thread on open.
	private func largeMarkdown(sections: Int = 60) -> String {
		var lines: [String] = []
		for i in 1...sections {
			lines.append("# Section \(i)")
			lines.append("")
			lines.append("Paragraph with [a link](https://example.com/\(i)) and *some* emphasis and **bold**.")
			lines.append("")
			lines.append("- bullet a")
			lines.append("- bullet b")
			lines.append("- bullet c")
			lines.append("")
			lines.append("```swift")
			lines.append("let x\(i) = \(i)")
			lines.append("print(x\(i))")
			lines.append("```")
			lines.append("")
			lines.append("| Col A | Col B | Col C |")
			lines.append("| ----- | ----- | ----- |")
			lines.append("| 1     | 2     | 3     |")
			lines.append("")
		}
		return lines.joined(separator: "\n")
	}

	@Test func render_returnsImmediately_thenFillsStorageAsynchronously() async throws {
		let parent = MarkdownTextView(text: largeMarkdown(), theme: .default, fontSize: 16)
		let coord = MarkdownTextView.Coordinator(parent: parent)
		let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))

		// Sanity check: storage starts empty.
		#expect(textView.textStorage?.length == 0)

		let start = Date()
		coord.render(into: textView)
		let elapsed = Date().timeIntervalSince(start)

		// Window-open used to wait for the entire parse + attachment build to
		// finish synchronously. Returning under 50ms here proves the parse
		// has been pushed off-main so updateNSView no longer blocks AppKit
		// from presenting the document window.
		#expect(elapsed < 0.05, "render() should return quickly, took \(elapsed * 1000) ms")
		#expect(textView.textStorage?.length == 0, "storage should still be empty immediately after render() returns")

		// Give the async parse + build a chance to land. The render task is
		// MainActor so we yield until it commits its setAttributedString.
		var attempts = 0
		while textView.textStorage?.length == 0, attempts < 40 {
			try? await Task.sleep(for: .milliseconds(50))
			attempts += 1
		}
		#expect((textView.textStorage?.length ?? 0) > 0, "storage should be populated after the async render completes")
	}

	@Test func render_secondCallWithSameTextSkipsWork() async throws {
		let parent = MarkdownTextView(text: "Hello world", theme: .default, fontSize: 16)
		let coord = MarkdownTextView.Coordinator(parent: parent)
		let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))

		coord.render(into: textView)
		// Wait for the first render to land.
		var attempts = 0
		while textView.textStorage?.length == 0, attempts < 40 {
			try? await Task.sleep(for: .milliseconds(25))
			attempts += 1
		}
		let firstLength = textView.textStorage?.length ?? 0
		#expect(firstLength > 0)

		// A second render with unchanged parent shouldn't start a new pass at
		// all — the lastRenderKey guard short-circuits before we cancel the
		// in-flight task. Storage stays exactly as it was.
		coord.render(into: textView)
		try? await Task.sleep(for: .milliseconds(100))
		#expect(textView.textStorage?.length == firstLength)
	}
}
#endif
