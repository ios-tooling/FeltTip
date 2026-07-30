#if os(macOS)
import SwiftUI
import Testing
@testable import MarkDownRange

@Suite("Raw editor text synchronization")
@MainActor
struct RawEditorTextSynchronizationTests {
	private func coordinator(text: String) -> MarkdownTextEditor.Coordinator {
		MarkdownTextEditor(
			text: .constant(text),
			selectedHeadingID: .constant(nil)
		).makeCoordinator()
	}

	@Test("Cursor-only host updates do not replace the text storage")
	func unchangedHostTextIsIgnored() {
		let source = String(repeating: "large document line\n", count: 100_000)
		let coordinator = coordinator(text: source)

		#expect(!coordinator.shouldReplaceViewText(
			previousHostText: source, incomingText: source))
	}

	@Test("A local edit round trip does not replace the live text storage")
	func acceptedLocalEditIsIgnored() {
		let coordinator = coordinator(text: "before")
		coordinator.pendingLocalText = "after"

		#expect(!coordinator.shouldReplaceViewText(
			previousHostText: "before", incomingText: "after"))
		#expect(coordinator.pendingLocalText == nil)
	}

	@Test("A rejected or superseded local edit restores host text")
	func supersededLocalEditIsReplaced() {
		let coordinator = coordinator(text: "before")
		coordinator.pendingLocalText = "local"

		#expect(coordinator.shouldReplaceViewText(
			previousHostText: "before", incomingText: "remote"))
		#expect(coordinator.pendingLocalText == nil)
	}

	@Test("An external host update replaces the text storage")
	func externalTextIsReplaced() {
		let coordinator = coordinator(text: "before")

		#expect(coordinator.shouldReplaceViewText(
			previousHostText: "before", incomingText: "after"))
	}
}
#endif
