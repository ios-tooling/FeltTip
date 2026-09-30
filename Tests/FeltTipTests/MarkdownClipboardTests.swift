#if os(macOS)
import AppKit
import Testing
@testable import FeltTip

@Suite("Markdown clipboard contract", .serialized)
@MainActor
struct MarkdownClipboardTests {
	@Test("The public source flavor is the one the editor reads")
	func publicSourceFlavorIsPasteable() async throws {
		await TestPasteboard.acquireExclusiveAccess()
		defer { TestPasteboard.releaseExclusiveAccess() }
		let pasteboard = NSPasteboard.general
		let sourceType = NSPasteboard.PasteboardType(
			MarkdownClipboard.sourcePasteboardType)
		let savedText = pasteboard.string(forType: .string)
		let savedSource = pasteboard.data(forType: sourceType)
		defer {
			pasteboard.clearContents()
			if let savedText { pasteboard.setString(savedText, forType: .string) }
			if let savedSource { pasteboard.setData(savedSource, forType: sourceType) }
		}

		let markdown = "# Heading\n\n- one\n- two"
		pasteboard.clearContents()
		pasteboard.setString("Heading\none\ntwo", forType: .string)
		pasteboard.setData(Data(markdown.utf8), forType: sourceType)

		#expect(MarkdownPasteboard.source == markdown)
		#expect(MarkdownPasteboard.text == "Heading\none\ntwo")
	}
}
#endif
