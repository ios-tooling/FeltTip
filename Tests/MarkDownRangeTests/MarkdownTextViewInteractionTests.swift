#if os(macOS)
import Testing
import Foundation
import AppKit
@testable import MarkDownRange

@Suite @MainActor struct MarkdownTextViewInteractionTests {
	private final class ScrollProbe {
		var reports: [(top: CGFloat, visible: CGFloat)] = []
	}

	private func makeScrollHarness(
		text: String = "Scroll test",
		onReport: @escaping @MainActor @Sendable (CGFloat, CGFloat, CGFloat) -> Void
	) -> (coordinator: MarkdownTextView.Coordinator, scrollView: NSScrollView, textView: NSTextView) {
		let parent = MarkdownTextView(text: text, theme: .default, fontSize: 16)
			.onScrollFractionChanged(onReport)
		let coordinator = MarkdownTextView.Coordinator(parent: parent)
		let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
		let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 2_000))
		textView.isVerticallyResizable = true
		textView.minSize = NSSize(width: 0, height: 0)
		textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
		textView.textContainer?.containerSize = NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
		scrollView.documentView = textView
		textView.setFrameSize(NSSize(width: 500, height: 2_000))
		textView.bounds = NSRect(x: 0, y: 0, width: 500, height: 2_000)
		scrollView.contentView.bounds = NSRect(x: 0, y: 0, width: 500, height: 400)
		coordinator.textView = textView
		return (coordinator, scrollView, textView)
	}

	private func commandEvent(_ key: String, shift: Bool = false) -> NSEvent {
		var flags: NSEvent.ModifierFlags = [.command]
		if shift { flags.insert(.shift) }
		return NSEvent.keyEvent(
			with: .keyDown,
			location: .zero,
			modifierFlags: flags,
			timestamp: 0,
			windowNumber: 0,
			context: nil,
			characters: key,
			charactersIgnoringModifiers: key,
			isARepeat: false,
			keyCode: 0
		)!
	}

	@Test func reportScrollFractionConvertsClipBoundsToFractions() {
		let probe = ScrollProbe()
		let harness = makeScrollHarness { top, visible, _ in probe.reports.append((top, visible)) }

		harness.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 500))
		harness.coordinator.reportScrollFraction(force: true)

		#expect(probe.reports.count == 1)
		#expect(abs((probe.reports.first?.top ?? 0) - 0.25) < 0.001)
		#expect(abs((probe.reports.first?.visible ?? 0) - 0.2) < 0.001)
	}

	@Test func duplicateScrollReportsAreSuppressedUntilPixelThresholdMoves() {
		let probe = ScrollProbe()
		let harness = makeScrollHarness { top, visible, _ in probe.reports.append((top, visible)) }

		harness.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 200))
		harness.coordinator.reportScrollFraction(force: true)
		harness.coordinator.reportScrollFraction()
		#expect(probe.reports.count == 1, "Unchanged metrics should not report twice")

		harness.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 200.25))
		harness.coordinator.reportScrollFraction()
		#expect(probe.reports.count == 1, "Sub-pixel movement should be suppressed")

		harness.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 201))
		harness.coordinator.reportScrollFraction()
		#expect(probe.reports.count == 2, "A real pixel movement should report")
	}

	@Test func forcedScrollReportsBypassDuplicateSuppression() {
		let probe = ScrollProbe()
		let harness = makeScrollHarness { top, visible, _ in probe.reports.append((top, visible)) }

		harness.coordinator.reportScrollFraction(force: true)
		harness.coordinator.reportScrollFraction(force: true)

		#expect(probe.reports.count == 2)
	}

	@Test func scheduledScrollReportsCoalesceWithinRunLoopTurn() async throws {
		let probe = ScrollProbe()
		let harness = makeScrollHarness { top, visible, _ in probe.reports.append((top, visible)) }

		harness.coordinator.scheduleScrollFractionReport(force: true)
		harness.coordinator.scheduleScrollFractionReport(force: true)
		harness.coordinator.scheduleScrollFractionReport(force: true)

		try await Task.sleep(for: .milliseconds(50))
		#expect(probe.reports.count == 1)
	}

	@Test func scrollDeltaClampsToDocumentEndAndTokenGatesRepeats() {
		let probe = ScrollProbe()
		let harness = makeScrollHarness { top, visible, _ in probe.reports.append((top, visible)) }
		harness.coordinator.parent = MarkdownTextView(text: "Scroll test", theme: .default, fontSize: 16)
			.scrollDelta(MarkdownScrollDelta(deltaY: 5_000, token: 1))

		harness.coordinator.handleScrollDelta(in: harness.textView)
		#expect(harness.scrollView.contentView.bounds.origin.y == 1_600)

		harness.scrollView.contentView.scroll(to: .zero)
		harness.coordinator.handleScrollDelta(in: harness.textView)
		#expect(harness.scrollView.contentView.bounds.origin.y == 0, "Same token should not apply twice")
	}

	@Test func scrollTargetCentersRequestedFractionAndTokenGatesRepeats() {
		let probe = ScrollProbe()
		let harness = makeScrollHarness { top, visible, _ in probe.reports.append((top, visible)) }
		harness.coordinator.parent = MarkdownTextView(text: "Scroll test", theme: .default, fontSize: 16)
			.scrollTarget(MarkdownScrollTarget(topFraction: 0.5, token: 1))

		harness.coordinator.handleScrollTarget(in: harness.textView)
		#expect(harness.scrollView.contentView.bounds.origin.y == 800)

		harness.scrollView.contentView.scroll(to: .zero)
		harness.coordinator.handleScrollTarget(in: harness.textView)
		#expect(harness.scrollView.contentView.bounds.origin.y == 0, "Same token should not apply twice")
	}

	@Test func formattingTextViewBoldCommandWrapsSelection() {
		let textView = MarkdownFormattingTextView()
		textView.string = "hello"
		textView.setSelectedRange(NSRange(location: 0, length: 5))

		#expect(textView.performKeyEquivalent(with: commandEvent("b")))
		#expect(textView.string == "**hello**")
		#expect(textView.selectedRange() == NSRange(location: 2, length: 5))
	}

	@Test func formattingTextViewBoldCommandUnwrapsExistingMarkers() {
		let textView = MarkdownFormattingTextView()
		textView.string = "**hello**"
		textView.setSelectedRange(NSRange(location: 2, length: 5))

		#expect(textView.performKeyEquivalent(with: commandEvent("b")))
		#expect(textView.string == "hello")
		#expect(textView.selectedRange() == NSRange(location: 0, length: 5))
	}

	@Test func formattingTextViewItalicCommandInsertsMarkersAtInsertionPoint() {
		let textView = MarkdownFormattingTextView()
		textView.string = ""
		textView.setSelectedRange(NSRange(location: 0, length: 0))

		#expect(textView.performKeyEquivalent(with: commandEvent("i")))
		#expect(textView.string == "__")
		#expect(textView.selectedRange() == NSRange(location: 1, length: 0))
	}

	@Test func formattingTextViewLinkCommandWrapsSelectionAndPlacesCursorInDestination() {
		let textView = MarkdownFormattingTextView()
		textView.string = "docs"
		textView.setSelectedRange(NSRange(location: 0, length: 4))

		#expect(textView.performKeyEquivalent(with: commandEvent("k")))
		#expect(textView.string == "[docs]()")
		#expect(textView.selectedRange() == NSRange(location: 7, length: 0))
	}

	@Test func formattingTextViewHeadingPromotionAndDemotionMutateCurrentLine() {
		let textView = MarkdownFormattingTextView()
		textView.string = "Title"
		textView.setSelectedRange(NSRange(location: 5, length: 0))

		#expect(textView.performKeyEquivalent(with: commandEvent("=")))
		#expect(textView.string == "# Title")

		#expect(textView.performKeyEquivalent(with: commandEvent("-")))
		#expect(textView.string == "## Title")
	}

	@Test func editableTextViewMapsSafeTextReplacementBackToSource() {
		var editedSource: String?
		let parent = MarkdownTextView(text: "hello world", theme: .default, fontSize: 16)
			.editable(true)
			.onSourceEdit { editedSource = $0 }
		let coordinator = MarkdownTextView.Coordinator(parent: parent)
		let textView = NSTextView()
		textView.textStorage?.setAttributedString(NSAttributedString(
			string: "hello world",
			attributes: [.markdownSourceOffset: 0]
		))

		let allowed = coordinator.textView(
			textView,
			shouldChangeTextInRanges: [NSValue(range: NSRange(location: 6, length: 5))],
			replacementStrings: ["there"]
		)

		#expect(!allowed)
		#expect(editedSource == "hello there")
		#expect(textView.string == "hello there")
	}

	@Test func editableTextViewMapsSequentialTypedReplacementBackToSource() {
		var editedSource = "The alpha insertion target sits here."
		let replacement = "alpha insertion target SMOKE-A"
		let parent = MarkdownTextView(text: editedSource, theme: .default, fontSize: 16)
			.editable(true)
			.onSourceEdit { editedSource = $0 }
		let coordinator = MarkdownTextView.Coordinator(parent: parent)
		let textView = NSTextView()
		textView.textStorage?.setAttributedString(NSAttributedString(
			string: "The alpha insertion target sits here.",
			attributes: [.markdownSourceOffset: 0]
		))
		var affected = NSRange(location: "The ".utf16.count, length: "alpha insertion target".utf16.count)

		for scalar in replacement.unicodeScalars {
			let string = String(scalar)
			let allowed = coordinator.textView(
				textView,
				shouldChangeTextInRanges: [NSValue(range: affected)],
				replacementStrings: [string]
			)
			#expect(!allowed)
			affected = NSRange(location: affected.location + string.utf16.count, length: 0)
		}

		#expect(editedSource == "The alpha insertion target SMOKE-A sits here.")
		#expect(textView.string == "The alpha insertion target SMOKE-A sits here.")
	}

	@Test func editableTextViewKeepsFollowingSourceOffsetsAfterLengthChangingReplacement() {
		var editedSource = """
		# Split Default Editing

		This paragraph contains raw target for the source pane.

		## Styled Section

		This part contains styled target for the rendered pane.
		"""
		let parent = MarkdownTextView(text: editedSource, theme: .default, fontSize: 16)
			.editable(true)
			.onSourceEdit { editedSource = $0 }
		let coordinator = MarkdownTextView.Coordinator(parent: parent)
		let paragraph = "This part contains styled target for the rendered pane."
		let paragraphSourceOffset = (editedSource as NSString).range(of: paragraph).location
		let textView = NSTextView()
		textView.textStorage?.setAttributedString(NSAttributedString(
			string: paragraph,
			attributes: [.markdownSourceOffset: paragraphSourceOffset]
		))

		let partRange = (paragraph as NSString).range(of: "part")
		let replacementAllowed = coordinator.textView(
			textView,
			shouldChangeTextInRanges: [NSValue(range: partRange)],
			replacementStrings: ["section"]
		)

		#expect(!replacementAllowed)
		#expect(editedSource.contains("This section contains styled target for the rendered pane."))

		let insertionPoint = (textView.string as NSString).range(of: ".").location
		let insertionAllowed = coordinator.textView(
			textView,
			shouldChangeTextInRanges: [NSValue(range: NSRange(location: insertionPoint, length: 0))],
			replacementStrings: [" with extra detail"]
		)

		#expect(!insertionAllowed)
		#expect(editedSource.contains("This section contains styled target for the rendered pane with extra detail."))
		#expect(textView.string == "This section contains styled target for the rendered pane with extra detail.")
	}

	@Test func editableTextViewMapsReplacementEndingAtInlineStyleBoundary() {
		var editedSource: String?
		let parent = MarkdownTextView(text: "a **bold** b", theme: .default, fontSize: 16)
			.editable(true)
			.onSourceEdit { editedSource = $0 }
		let coordinator = MarkdownTextView.Coordinator(parent: parent)
		let storage = NSMutableAttributedString(string: "a bold b")
		storage.addAttribute(.markdownSourceOffset, value: 0, range: NSRange(location: 0, length: 2))
		storage.addAttribute(.markdownSourceOffset, value: 4, range: NSRange(location: 2, length: 4))
		storage.addAttribute(.markdownSourceOffset, value: 10, range: NSRange(location: 6, length: 2))
		let textView = NSTextView()
		textView.textStorage?.setAttributedString(storage)

		let allowed = coordinator.textView(
			textView,
			shouldChangeTextInRanges: [NSValue(range: NSRange(location: 2, length: 4))],
			replacementStrings: ["strong"]
		)

		#expect(!allowed)
		#expect(editedSource == "a **strong** b")
		#expect(textView.string == "a strong b")
	}

	@Test func editableTextViewMapsReplacementInsideLinkLabelOnly() {
		var editedSource: String?
		let source = "Visit [Marker documentation](https://example.com/marker-docs) today."
		let parent = MarkdownTextView(text: source, theme: .default, fontSize: 16)
			.editable(true)
			.onSourceEdit { editedSource = $0 }
		let coordinator = MarkdownTextView.Coordinator(parent: parent)
		let storage = NSMutableAttributedString(string: "Visit Marker documentation today.")
		storage.addAttribute(.markdownSourceOffset, value: 0, range: NSRange(location: 0, length: 6))
		storage.addAttribute(.markdownSourceOffset, value: 7, range: NSRange(location: 6, length: 20))
		storage.addAttribute(.markdownSourceOffset, value: 55, range: NSRange(location: 26, length: 7))
		let textView = NSTextView()
		textView.textStorage?.setAttributedString(storage)

		let allowed = coordinator.textView(
			textView,
			shouldChangeTextInRanges: [NSValue(range: NSRange(location: 6, length: 20))],
			replacementStrings: ["Marker documentation SMOKE-LINK"]
		)

		#expect(!allowed)
		#expect(editedSource == "Visit [Marker documentation SMOKE-LINK](https://example.com/marker-docs) today.")
		#expect(textView.string == "Visit Marker documentation SMOKE-LINK today.")
	}

	@Test func editableTextViewRejectsReplacementThatCrossesMarkdownSyntax() {
		var editedSource: String?
		let parent = MarkdownTextView(text: "a **bold** b", theme: .default, fontSize: 16)
			.editable(true)
			.onSourceEdit { editedSource = $0 }
		let coordinator = MarkdownTextView.Coordinator(parent: parent)
		let storage = NSMutableAttributedString(string: "a bold b")
		storage.addAttribute(.markdownSourceOffset, value: 0, range: NSRange(location: 0, length: 2))
		storage.addAttribute(.markdownSourceOffset, value: 4, range: NSRange(location: 2, length: 4))
		storage.addAttribute(.markdownSourceOffset, value: 10, range: NSRange(location: 6, length: 2))
		let textView = NSTextView()
		textView.textStorage?.setAttributedString(storage)

		let allowed = coordinator.textView(
			textView,
			shouldChangeTextInRanges: [NSValue(range: NSRange(location: 0, length: 6))],
			replacementStrings: ["plain"]
		)

		#expect(!allowed)
		#expect(editedSource == nil)
	}

	@Test func requestEditLinkURLReportsOccurrenceAmongDuplicateDestinations() {
		var request: (url: String, occurrence: Int)?
		let parent = MarkdownTextView(text: "[one](https://example.com) [two](https://example.com)", theme: .default, fontSize: 16)
			.onRequestEditLinkURL { url, occurrence in request = (url, occurrence) }
		let coordinator = MarkdownTextView.Coordinator(parent: parent)
		let storage = NSMutableAttributedString(string: "one two")
		storage.addAttribute(.link, value: URL(string: "https://example.com")!, range: NSRange(location: 0, length: 3))
		storage.addAttribute(.link, value: URL(string: "https://example.com")!, range: NSRange(location: 4, length: 3))
		let textView = NSTextView()
		textView.textStorage?.setAttributedString(storage)
		coordinator.textView = textView

		coordinator.requestEditLinkURL(atRenderedIndex: 5)

		#expect(request?.url == "https://example.com")
		#expect(request?.occurrence == 1)
	}
}
#endif
