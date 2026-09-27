#if os(macOS)
import SwiftUI
import Testing
@testable import FeltTip

@MainActor
private final class RawEditorCancellationFlag {
	var wasCancelled = false
}

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

	@Test("Closing a raw editor cancels outstanding prelayout")
	func closingEditorCancelsPrelayout() async {
		let flag = RawEditorCancellationFlag()
		var coordinator: MarkdownTextEditor.Coordinator? = coordinator(text: "large document")
		coordinator?.prelayoutTask = Task { @MainActor in
			do {
				try await Task.sleep(for: .seconds(5))
			} catch {
				flag.wasCancelled = Task.isCancelled
			}
		}

		coordinator = nil
		for _ in 0..<50 where !flag.wasCancelled {
			try? await Task.sleep(for: .milliseconds(10))
		}

		#expect(flag.wasCancelled)
	}

	@Test("A revision-matched heading index serves the raw scroll lookup")
	func matchingHeadingIndexIsUsed() {
		let source = "# First\n\nbody\n\n## Second"
		let coordinator = coordinator(text: source)
		let headings = MarkdownHeading.parse(from: source)
		coordinator.indexedHeadings = headings
		coordinator.indexedHeadingRevision = coordinator.contentRevision
		let secondOffset = (source as NSString).range(of: "## Second").location

		// Pass deliberately unrelated fallback text: a matching index should
		// resolve from its own exact-revision ranges without scanning it.
		let heading = coordinator.visibleHeading(
			at: secondOffset, in: "not the indexed source")

		#expect(heading?.id == headings.last?.id)
	}

	@Test("A stale heading index falls back to the live source")
	func staleHeadingIndexIsNeverUsed() {
		let original = "# Old heading"
		let coordinator = coordinator(text: original)
		coordinator.indexedHeadings = MarkdownHeading.parse(from: original)
		coordinator.indexedHeadingRevision = coordinator.contentRevision

		// NSTextStorage character edits advance the exact revision used to
		// gate the asynchronous index. The old index must now be ignored.
		let current = "# Current heading"
		coordinator.textStorage(
			NSTextStorage(string: current),
			didProcessEditing: .editedCharacters,
			range: NSRange(location: 0, length: (current as NSString).length),
			changeInLength: (current as NSString).length - (original as NSString).length)

		let heading = coordinator.visibleHeading(at: 0, in: current)

		#expect(heading?.text == "Current heading")
	}

	@Test("Appending at an unterminated fence EOF extends its cached range")
	func appendAtUnterminatedFenceEndStaysInsideFence() {
		let original = "```\nlet value = "
		let appended = "**code**"
		let current = original + appended
		let coordinator = coordinator(text: original)
		coordinator.codeFenceRanges = MarkdownSyntaxHighlighter.fenceRanges(
			in: original)

		coordinator.textStorage(
			NSTextStorage(string: current),
			didProcessEditing: .editedCharacters,
			range: NSRange(
				location: (original as NSString).length,
				length: (appended as NSString).length),
			changeInLength: (appended as NSString).length)

		#expect(coordinator.codeFenceRanges == [
			NSRange(location: 0, length: (current as NSString).length)
		])
	}

	@Test("Appending after a closed EOF fence does not extend its cached range")
	func appendAfterClosedFenceEndStaysOutsideFence() {
		let original = "```\nlet value = 1\n```"
		let appended = " plain"
		let current = original + appended
		let originalRanges = MarkdownSyntaxHighlighter.fenceRanges(in: original)
		let coordinator = coordinator(text: original)
		coordinator.codeFenceRanges = originalRanges

		coordinator.textStorage(
			NSTextStorage(string: current),
			didProcessEditing: .editedCharacters,
			range: NSRange(
				location: (original as NSString).length,
				length: (appended as NSString).length),
			changeInLength: (appended as NSString).length)

		#expect(coordinator.codeFenceRanges == originalRanges)
	}
}
#endif
