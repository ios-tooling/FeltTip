#if os(macOS)
	import AppKit
#else
	import UIKit
#endif
import Observation
import SwiftUI
import Testing
@testable import FeltTip

// The styled/raw handoff is tested against the macOS NSTextView editor,
// which has no iOS counterpart — the iOS raw editor is MarkdownUITextEditor,
// with its own coverage. Keep this suite macOS-only.
#if os(macOS)

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
		let mirrorCount = harness.selectionReportCount
		try await harness.run("""
			window.__mdPlaceCaret(\(selected.location), \(selected.length))
			document.dispatchEvent(new Event('selectionchange'))
			""")
		let selectedWithFormatting = (source as NSString).range(of: "**bravo**")
		try await harness.waitUntil("extended exact and mirror selections") {
			harness.sourceSelectionReportCount > exactCount
				&& harness.selectionReportCount > mirrorCount
				&& harness.lastReportedSourceSelection == selectedWithFormatting
				&& harness.lastReportedSelection == selectedWithFormatting
		}
	}

	@Test func paragraphSelectionStopsBeforeTheSeparatorAndNextBlocksFormatting() async throws {
		let source = "Intro\n\n**Chosen paragraph.**\n \t\n**Next paragraph.**"
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

		let expected = (source as NSString).range(of: "**Chosen paragraph.**")
		#expect(harness.lastReportedSourceSelection == expected)
		#expect((source as NSString).substring(with: expected) == "**Chosen paragraph.**")
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

	@Test func staleAndOutOfBoundsSelectionMessagesAreDroppedWithoutCrashing() async throws {
		let source = "**Alpha** Tail"
		let harness = try await CoordinatorBridgeHarness(source: source)
		let reportCount = harness.sourceSelectionReportCount
		let currentRevision = harness.coordinator.currentRev
		try await harness.run("""
			window.webkit.messageHandlers.mdedit.postMessage({
			  type: 'selection', start: 2, length: 5,
			  syntaxStart: ['strong'], syntaxEnd: ['strong']
			})
			window.webkit.messageHandlers.mdedit.postMessage({
			  type: 'selection', start: 2, length: 5,
			  syntaxStart: ['strong'], syntaxEnd: ['strong'],
			  rev: \(currentRevision - 1)
			})
			window.webkit.messageHandlers.mdedit.postMessage({
			  type: 'selection', start: 999999, length: 20,
			  syntaxStart: ['strong'], syntaxEnd: ['strong'],
			  rev: \(currentRevision)
			})
			""")
		try await Task.sleep(for: .milliseconds(150))
		#expect(harness.sourceSelectionReportCount == reportCount)

		// A valid current-revision report still works after every rejected input.
		try await harness.run("""
			window.webkit.messageHandlers.mdedit.postMessage({
			  type: 'selection', start: 2, length: 5,
			  syntaxStart: ['strong'], syntaxEnd: ['strong'],
			  rev: \(currentRevision)
			})
			""")
		try await harness.waitUntil("valid selection after rejected metadata") {
			harness.sourceSelectionReportCount > reportCount
		}
		#expect(harness.lastReportedSourceSelection == NSRange(
			location: 0, length: ("**Alpha**" as NSString).length))
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

	@Test func styledViewRestoresSelectionAfterHiddenKramdownAttributeLine() async throws {
		let source = """
		# Before

		Paragraph before.

		{: .callout #intro}

		Paragraph after token: LOCAL UNSAVED

		## End
		"""
		let selected = (source as NSString).range(of: "LOCAL UNSAVED")
		let harness = try await CoordinatorBridgeHarness(source: source)

		harness.coordinator.parent = MarkdownWebView(
			text: source, theme: .default, fontSize: 14
		)
		.editable(true)
		.selectionTarget(MarkdownSelectionTarget(range: selected, token: 1))
		harness.coordinator.applySelectionTarget(to: harness.webView)

		try await harness.waitUntil("selection after hidden Kramdown attributes") {
			try await harness.evaluate("window.getSelection().toString()") == "LOCAL UNSAVED"
		}
		#expect(try await harness.evaluate("window.getSelection().toString()") == "LOCAL UNSAVED")
	}

	@Test func inactiveStyledViewDefersSelectionTargetUntilRevealed() async throws {
		let source = "# Heading\n\nbody tail"
		let target = NSRange(
			location: (source as NSString).range(of: "tail").location + 2,
			length: 0)
		let handoff = MarkdownSelectionTarget(range: target, token: 1)
		let harness = try await CoordinatorBridgeHarness(source: source)

		harness.coordinator.parent = MarkdownWebView(
			text: source, theme: .default, fontSize: 14
		)
		.editable(true)
		.selectionTarget(handoff)
		.inactive(true)
		harness.coordinator.applySelectionTarget(to: harness.webView)

		// The hidden page retains an unrelated old caret. Revealing it with the
		// same token must still install the incoming editor's selection.
		try await harness.placeCaret(2)
		harness.coordinator.parent = MarkdownWebView(
			text: source, theme: .default, fontSize: 14
		)
		.editable(true)
		.selectionTarget(handoff)
		.onSourceEdit { [weak harness] newText, _ in
			harness?.recordExternalEdit(newText)
		}
		harness.coordinator.applySelectionTarget(to: harness.webView)
		try await harness.type("X")
		try await harness.waitForSourceEdits(1)

		let expected = (source as NSString).replacingCharacters(in: target, with: "X")
		#expect(harness.source == expected)
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

		hosting.layoutSubtreeIfNeeded()
		let textView = try #require(try await waitForTextView(in: hosting))
		#expect(textView.selectedRange() == NSRange(location: 8, length: 2))
		#expect((textView.string as NSString).substring(with: textView.selectedRange()) == "89")
	}

	@Test func rawEditorReportsCursorAfterInstallingSelectionTarget() async throws {
		let source = "# Heading\n\nsecond line\n"
		let target = (source as NSString).length
		let expected = MarkdownLineIndex(text: source).position(at: target)
		var text = source
		var heading: String?
		var reports: [(line: Int, column: Int, offset: Int)] = []
		let root = RawMarkdownScreen(
			text: Binding(get: { text }, set: { text = $0 }),
			selectedHeadingID: Binding(get: { heading }, set: { heading = $0 }),
			fontSize: 14,
			onCursorPositionChanged: { line, column, _, offset in
				reports.append((line, column, offset))
			},
			selectionTarget: MarkdownSelectionTarget(
				range: NSRange(location: target, length: 0), token: 1)
		)
		let hosting = NSHostingView(rootView: root)
		hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
		let window = NSWindow(
			contentRect: hosting.frame, styleMask: [.borderless],
			backing: .buffered, defer: false)
		window.contentView = hosting
		window.orderFront(nil)

		hosting.layoutSubtreeIfNeeded()
		_ = try #require(try await waitForTextView(in: hosting))
		for _ in 0..<40 where reports.last?.offset != target {
			try await Task.sleep(for: .milliseconds(25))
		}

		#expect(reports.last?.offset == target)
		#expect(reports.last?.line == expected.line)
		#expect(reports.last?.column == expected.column)
	}

	@Test func rawEditorKeepsAnExtendedHandoffSelectionVisibleAfterViewportRestore() async throws {
		let source = (0..<420).map { index in
			"## Sector \(index)\n\nTransfer sentence \(index) records enough text to make the document scroll."
		}.joined(separator: "\n\n")
		let selected = (source as NSString).range(of: "## Sector 0")
		let model = RawSelectionViewportModel(source: source, selected: selected)
		let root = RawSelectionViewportHost(model: model)
		let hosting = NSHostingView(rootView: root)
		hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
		let window = NSWindow(
			contentRect: hosting.frame, styleMask: [.borderless],
			backing: .buffered, defer: false)
		window.contentView = hosting
		window.orderFront(nil)

		hosting.layoutSubtreeIfNeeded()
		let textView = try #require(try await waitForTextView(in: hosting))
		try await Task.sleep(for: .milliseconds(200))
		// Cursor/status publication re-renders Marker after the initial handoff.
		// Model that later pass with another stale normalized fraction.
		model.syncFraction = 0.8
		try await Task.sleep(for: .milliseconds(100))
		// A sidebar/window resize can schedule several delayed viewport restores.
		// None of them may outlive and hide the stronger selection handoff.
		window.setContentSize(NSSize(width: 430, height: 400))
		hosting.layoutSubtreeIfNeeded()
		try await Task.sleep(for: .milliseconds(1_200))
		hosting.layoutSubtreeIfNeeded()

		#expect(textView.selectedRange() == selected)
		let scrollView = try #require(textView.enclosingScrollView)
		let span = max(0,
			(scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height)
		let fraction = span > 0 ? scrollView.contentView.bounds.origin.y / span : 0
		#expect(fraction < 0.1,
			"The selected top title was hidden by a stale viewport restore at \(fraction)")
	}

	@Test func rawEditorReleasesExtendedSelectionAfterTheHandoffSettles() async throws {
		let source = (0..<420).map { index in
			"## Sector \(index)\n\nTransfer sentence \(index) records enough text to make the document scroll."
		}.joined(separator: "\n\n")
		let selected = (source as NSString).range(of: "## Sector 0")
		let model = RawSelectionViewportModel(source: source, selected: selected)
		let hosting = NSHostingView(rootView: RawSelectionViewportHost(model: model))
		hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
		let window = NSWindow(
			contentRect: hosting.frame, styleMask: [.borderless],
			backing: .buffered, defer: false)
		window.contentView = hosting
		window.orderFront(nil)

		hosting.layoutSubtreeIfNeeded()
		let textView = try #require(try await waitForTextView(in: hosting))
		try await Task.sleep(for: .milliseconds(500))
		// Once the handoff's late-layout window has elapsed, a real split-pane
		// scroll must be allowed to move the selection offscreen.
		model.syncFraction = 0.65
		for _ in 0..<40 {
			hosting.layoutSubtreeIfNeeded()
			let scrollView = try #require(textView.enclosingScrollView)
			let span = max(0,
				(scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height)
			let fraction = span > 0 ? scrollView.contentView.bounds.origin.y / span : 0
			if abs(fraction - 0.65) < 0.05 { break }
			try await Task.sleep(for: .milliseconds(25))
		}

		#expect(textView.selectedRange() == selected)
		let scrollView = try #require(textView.enclosingScrollView)
		let span = max(0,
			(scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height)
		let fraction = span > 0 ? scrollView.contentView.bounds.origin.y / span : 0
		#expect(abs(fraction - 0.65) < 0.05,
			"The persistent selection kept split scrolling pinned at \(fraction)")
	}

	@Test func rawEditorRevealsInitialExtendedSelectionAfterLateLayoutScroll() async throws {
		let source = (0..<1_600).map { index in
			"## Sector \(index)\n\nTransfer sentence \(index) records enough text to make the document scroll."
		}.joined(separator: "\n\n")
		let selected = (source as NSString).range(of: "## Sector 0")
		var text = source
		var heading: String?
		let root = RawMarkdownScreen(
			text: Binding(get: { text }, set: { text = $0 }),
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

		hosting.layoutSubtreeIfNeeded()
		let textView = try #require(try await waitForTextView(in: hosting))
		let scrollView = try #require(textView.enclosingScrollView)
		let span = max(0,
			(scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height)
		scrollView.contentView.scroll(to: NSPoint(
			x: scrollView.contentView.bounds.origin.x, y: span * 0.8))
		scrollView.reflectScrolledClipView(scrollView.contentView)

		try await Task.sleep(for: .milliseconds(200))
		hosting.layoutSubtreeIfNeeded()
		let settledSpan = max(0,
			(scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height)
		let fraction = settledSpan > 0 ? scrollView.contentView.bounds.origin.y / settledSpan : 0
		#expect(textView.selectedRange() == selected)
		#expect(fraction < 0.1,
			"The initial selection reveal was lost during late layout at \(fraction)")
	}

	@Test func rawEditorRestoresCollapsedCaretViewportAfterLateLayout() async throws {
		let source = (0..<1_600).map { index in
			"## Sector \(index)\n\nTransfer sentence \(index) records enough text to make the document scroll."
		}.joined(separator: "\n\n")
		let caret = (source as NSString).range(of: "Sector 800").location
		var text = source
		var heading: String?
		let root = RawMarkdownScreen(
			text: Binding(get: { text }, set: { text = $0 }),
			selectedHeadingID: Binding(get: { heading }, set: { heading = $0 }),
			fontSize: 14,
			syncScrollFraction: 0.5,
			scrollTarget: MarkdownScrollTarget(topFraction: 0.5, token: 1),
			selectionTarget: MarkdownSelectionTarget(
				range: NSRange(location: caret, length: 0), token: 1)
		)
		let hosting = NSHostingView(rootView: root)
		hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
		let window = NSWindow(
			contentRect: hosting.frame, styleMask: [.borderless],
			backing: .buffered, defer: false)
		window.contentView = hosting
		window.orderFront(nil)

		hosting.layoutSubtreeIfNeeded()
		let textView = try #require(try await waitForTextView(in: hosting))
		let scrollView = try #require(textView.enclosingScrollView)
		for _ in 0..<120 where !caretIsVisible(caret, in: textView, scrollView: scrollView) {
			hosting.layoutSubtreeIfNeeded()
			try await Task.sleep(for: .milliseconds(25))
		}

		#expect(textView.selectedRange() == NSRange(location: caret, length: 0))
		#expect(caretIsVisible(caret, in: textView, scrollView: scrollView),
			"The restored caret was left outside the settled viewport")
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

		hosting.layoutSubtreeIfNeeded()
		let textView = try #require(try await waitForTextView(in: hosting))
		#expect(textView.selectedRange() == selected)
		#expect((textView.string as NSString).substring(with: selected) == "😀 cafe\u{301} 👩‍💻")
	}

	@Test func styledSelectionTargetExpandsEndpointsToWholeGraphemes() async throws {
		let source = "ae\u{301} 👩‍💻z"
		let harness = try await CoordinatorBridgeHarness(source: source)
		// Starts on the combining accent and ends between the ZWJ and laptop.
		let partial = NSRange(location: 2, length: 5)

		harness.coordinator.parent = MarkdownWebView(
			text: source, theme: .default, fontSize: 14
		)
		.editable(true)
		.selectionTarget(MarkdownSelectionTarget(range: partial, token: 1))
		.onSourceEdit { [weak harness] newText, _ in
			harness?.recordExternalEdit(newText)
		}
		harness.coordinator.applySelectionTarget(to: harness.webView)
		try await harness.waitUntil("composed styled selection target") {
			try await harness.evaluate("window.getSelection().toString()") == "e\u{301} 👩‍💻"
		}

		try await harness.type("X")
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "aXz")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(try await harness.stampMismatches() == [])
	}

	@Test(arguments: [
		(range: NSRange(location: 0, length: 9), selected: "AB", expected: "X"),
		(range: NSRange(location: 0, length: 8), selected: "A", expected: "XB"),
		(range: NSRange(location: 1, length: 8), selected: "B", expected: "AX"),
	])
	func restoredSelectionsAcrossAnEmptyUnderlineReplaceTheirWholeSourceRange(
		range: NSRange,
		selected: String,
		expected: String
	) async throws {
		let source = "A<u></u>B"
		let harness = try await CoordinatorBridgeHarness(source: source)
		harness.coordinator.parent = MarkdownWebView(
			text: source, theme: .default, fontSize: 14
		)
		.editable(true)
		.selectionTarget(MarkdownSelectionTarget(range: range, token: 2))
		.onSourceEdit { [weak harness] newText, _ in
			harness?.recordExternalEdit(newText)
		}
		harness.coordinator.applySelectionTarget(to: harness.webView)
		try await harness.waitUntil("selection spanning an empty underline") {
			try await harness.evaluate("window.getSelection().toString()") == selected
		}
		harness.rewireRoundTrip()

		try await harness.type("X")
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		#expect(harness.source == expected)
		#expect(harness.coordinator.resyncCount == 0,
			"incidents: \(harness.coordinator.bridgeIncidents), reason: \(harness.coordinator.lastResyncReason ?? "none")")
		#expect(harness.coordinator.hardRejections == 0)
		#expect(try await harness.stampMismatches() == [])
	}

	private func findTextView(in view: NSView) -> NSTextView? {
		if let textView = view as? NSTextView { return textView }
		for child in view.subviews {
			if let found = findTextView(in: child) { return found }
		}
		return nil
	}

	private func waitForTextView(in view: NSView) async throws -> NSTextView? {
		for _ in 0..<200 {
			if let editor = findTextView(in: view) { return editor }
			try await Task.sleep(for: .milliseconds(25))
		}
		return nil
	}

	private func caretIsVisible(
		_ location: Int, in textView: NSTextView, scrollView: NSScrollView
	) -> Bool {
		guard let layoutManager = textView.layoutManager else { return false }
		layoutManager.ensureLayout(forCharacterRange: NSRange(location: location, length: 0))
		let glyph = layoutManager.glyphRange(
			forCharacterRange: NSRange(location: location, length: 0),
			actualCharacterRange: nil)
		guard glyph.location < layoutManager.numberOfGlyphs else { return false }
		let textRect = layoutManager.boundingRect(
			forGlyphRange: NSRange(location: glyph.location, length: 1),
			in: textView.textContainer!)
			.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
		let clipRect = textView.convert(textRect, to: scrollView.contentView)
		return scrollView.contentView.bounds.intersects(clipRect)
	}
}

@MainActor @Observable
private final class RawSelectionViewportModel {
	var text: String
	var heading: String?
	var syncFraction = 0.9
	let selected: NSRange

	init(source: String, selected: NSRange) {
		text = source
		self.selected = selected
	}
}

private struct RawSelectionViewportHost: View {
	@Bindable var model: RawSelectionViewportModel

	var body: some View {
		RawMarkdownScreen(
			text: $model.text,
			selectedHeadingID: $model.heading,
			fontSize: 14,
			syncScrollFraction: model.syncFraction,
			scrollTarget: MarkdownScrollTarget(topFraction: 0.9, token: 1),
			selectionTarget: MarkdownSelectionTarget(range: model.selected, token: 1)
		)
	}
}
#endif
