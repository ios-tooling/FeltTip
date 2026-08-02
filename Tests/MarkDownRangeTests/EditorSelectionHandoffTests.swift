#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import MarkDownRange

@Suite("Editor selection handoff", .serialized)
@MainActor
struct EditorSelectionHandoffTests {
	@Test func styledViewReportsCollapsedAndExtendedSourceRangesSeparatelyFromMirrors() async throws {
		let source = "Zero alpha **bravo** charlie omega"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.run("document.hasFocus = function () { return true }")

		let caret = (source as NSString).range(of: "alpha").upperBound
		let oldExactCount = harness.sourceSelectionReportCount
		let oldMirrorCount = harness.selectionReportCount
		try await harness.placeCaret(caret)
		try await harness.run("document.dispatchEvent(new Event('selectionchange'))")
		try await harness.waitUntil("collapsed source selection") {
			harness.sourceSelectionReportCount > oldExactCount
				&& harness.selectionReportCount > oldMirrorCount
		}
		#expect(harness.lastReportedSourceSelection == NSRange(location: caret, length: 0))
		#expect(harness.lastReportedSelection == nil)

		let selected = (source as NSString).range(of: "bravo")
		let exactCount = harness.sourceSelectionReportCount
		try await harness.run("""
			window.__mdPlaceCaret(\(selected.location), \(selected.length))
			document.dispatchEvent(new Event('selectionchange'))
			""")
		try await harness.waitUntil("extended source selection") {
			harness.sourceSelectionReportCount > exactCount
		}
		let selectedWithFormatting = (source as NSString).range(of: "**bravo**")
		#expect(harness.lastReportedSourceSelection == selectedWithFormatting)
		#expect(harness.lastReportedSelection == selectedWithFormatting)
	}

	@Test func paragraphSelectionStopsBeforeTheNextBlocksHiddenFormatting() async throws {
		let source = "Intro\n\n**Chosen paragraph.**\n\n**Next paragraph.**"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.run("document.hasFocus = function () { return true }")
		let oldCount = harness.sourceSelectionReportCount

		try await harness.run("""
			var paragraphs = document.querySelectorAll('p')
			var first = paragraphs[1].querySelector('[data-s]').firstChild
			var next = paragraphs[2].querySelector('[data-s]').firstChild
			var range = document.createRange()
			range.setStart(first, 0)
			range.setEnd(next, 0)
			var selection = window.getSelection()
			selection.removeAllRanges()
			selection.addRange(range)
			document.dispatchEvent(new Event('selectionchange'))
			""")
		try await harness.waitUntil("paragraph source selection") {
			harness.sourceSelectionReportCount > oldCount
		}

		let start = (source as NSString).range(of: "**Chosen paragraph.**").location
		let nextLine = (source as NSString).range(of: "**Next paragraph.**").location
		let expected = NSRange(location: start, length: nextLine - start)
		#expect(harness.lastReportedSourceSelection == expected)
		#expect((source as NSString).substring(with: expected) == "**Chosen paragraph.**\n\n")
	}

	@Test func wholeFormattedWordSelectionIncludesItsAttachedDelimiters() async throws {
		let cases = ["**word**", "__word__", "_word_", "~~word~~"]
		for source in cases {
			let harness = try await CoordinatorBridgeHarness(source: source)
			try await harness.run("document.hasFocus = function () { return true }")
			let oldCount = harness.sourceSelectionReportCount
			try await harness.run("""
				var text = document.querySelector('[data-s]').firstChild
				var range = document.createRange()
				range.selectNodeContents(text)
				var selection = window.getSelection()
				selection.removeAllRanges()
				selection.addRange(range)
				document.dispatchEvent(new Event('selectionchange'))
				""")
			try await harness.waitUntil("formatted word source selection") {
				harness.sourceSelectionReportCount > oldCount
			}
			#expect(harness.lastReportedSourceSelection == NSRange(
				location: 0, length: (source as NSString).length), "source=\(source)")
		}
	}

	@Test func styledViewInstallsTokenGatedCaretAndSelectionTargets() async throws {
		let source = "Zero alpha **bravo** charlie omega"
		let harness = try await CoordinatorBridgeHarness(source: source)
		let bravo = (source as NSString).range(of: "bravo")

		harness.coordinator.parent = MarkdownWebView(
			text: source, theme: .default, fontSize: 14
		)
		.editable(true)
		.selectionTarget(MarkdownSelectionTarget(range: bravo, token: 1))
		harness.coordinator.applySelectionTarget(to: harness.webView)
		try await harness.waitUntil("styled selection target") {
			try await harness.evaluate("window.getSelection().toString()") == "bravo"
		}

		let caret = (source as NSString).range(of: "charlie").upperBound
		harness.coordinator.parent = MarkdownWebView(
			text: source, theme: .default, fontSize: 14
		)
		.editable(true)
		.selectionTarget(MarkdownSelectionTarget(
			range: NSRange(location: caret, length: 0), token: 2))
		harness.coordinator.applySelectionTarget(to: harness.webView)
		try await harness.waitUntil("styled caret target") {
			try await harness.evaluate("""
				(function () {
				  var s = window.getSelection()
				  if (!s || !s.rangeCount || !s.isCollapsed) return 'no'
				  var r = s.getRangeAt(0)
				  var n = r.startContainer.parentElement
				  return n && n.getAttribute('data-s') !== null ? 'yes' : 'no'
				})()
				""") == "yes"
		}
	}

	@Test func styledBlurPublishesTheFinalRangeEvenAfterFocusMovesToTheModeControl() async throws {
		let source = "Alpha bravo charlie"
		let range = (source as NSString).range(of: "bravo")
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.run("""
			document.hasFocus = function () { return false }
			window.__mdPlaceCaret(\(range.location), \(range.length))
			""")
		let oldCount = harness.sourceSelectionReportCount
		try await harness.run("window.dispatchEvent(new Event('blur'))")
		try await harness.waitUntil("blur selection report") {
			harness.sourceSelectionReportCount > oldCount
		}
		#expect(harness.lastReportedSourceSelection == range)
		#expect(harness.lastReportedSelection == range)
	}

	@Test func rawEditorInstallsAndClampsSelectionTargets() async throws {
		var text = "0123456789"
		var heading: String?
		let root = RawMarkdownScreen(
			text: Binding(get: { text }, set: { text = $0 }),
			selectedHeadingID: Binding(get: { heading }, set: { heading = $0 }),
			fontSize: 14,
			selectionTarget: MarkdownSelectionTarget(
				range: NSRange(location: 8, length: 99), token: 1)
		)
		let hosting = NSHostingView(rootView: root)
		hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
		let window = NSWindow(
			contentRect: hosting.frame, styleMask: [.borderless],
			backing: .buffered, defer: false)
		window.contentView = hosting
		window.orderFront(nil)

		var editor: NSTextView?
		for _ in 0..<40 where editor == nil {
			editor = findTextView(in: hosting)
			if editor == nil { try await Task.sleep(for: .milliseconds(25)) }
		}
		let textView = try #require(editor)
		#expect(textView.selectedRange() == NSRange(location: 8, length: 2))
		#expect((textView.string as NSString).substring(with: textView.selectedRange()) == "89")
	}

	@Test func unicodeSelectionRoundTripsThroughStyledAndRawHandoffs() async throws {
		let source = "Alpha 😀 cafe\u{301} 👩‍💻 omega"
		let selected = (source as NSString).range(of: "😀 cafe\u{301} 👩‍💻")
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.run("""
			document.hasFocus = function () { return true }
			window.__mdPlaceCaret(\(selected.location), \(selected.length))
			document.dispatchEvent(new Event('selectionchange'))
			""")
		try await harness.waitUntil("Unicode styled source selection") {
			harness.lastReportedSourceSelection == selected
		}
		#expect(harness.lastReportedSelection == selected)

		var rawText = source
		var heading: String?
		let root = RawMarkdownScreen(
			text: Binding(get: { rawText }, set: { rawText = $0 }),
			selectedHeadingID: Binding(get: { heading }, set: { heading = $0 }),
			fontSize: 14,
			selectionTarget: MarkdownSelectionTarget(range: selected, token: 1)
		)
		let hosting = NSHostingView(rootView: root)
		hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
		let window = NSWindow(
			contentRect: hosting.frame, styleMask: [.borderless],
			backing: .buffered, defer: false)
		window.contentView = hosting
		window.orderFront(nil)

		var editor: NSTextView?
		for _ in 0..<40 where editor == nil {
			editor = findTextView(in: hosting)
			if editor == nil { try await Task.sleep(for: .milliseconds(25)) }
		}
		let textView = try #require(editor)
		#expect(textView.selectedRange() == selected)
		#expect((textView.string as NSString).substring(with: selected) == "😀 cafe\u{301} 👩‍💻")
	}

	private func findTextView(in view: NSView) -> NSTextView? {
		if let textView = view as? NSTextView { return textView }
		for child in view.subviews {
			if let found = findTextView(in: child) { return found }
		}
		return nil
	}
}
#endif
