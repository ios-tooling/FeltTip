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
		#expect(harness.lastReportedSourceSelection == selected)
		#expect(harness.lastReportedSelection == selected)
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

	private func findTextView(in view: NSView) -> NSTextView? {
		if let textView = view as? NSTextView { return textView }
		for child in view.subviews {
			if let found = findTextView(in: child) { return found }
		}
		return nil
	}
}
#endif
