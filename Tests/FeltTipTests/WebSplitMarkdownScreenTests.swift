#if os(macOS)
import AppKit
import Observation
import SwiftUI
import Testing
import WebKit
@testable import FeltTip

@MainActor
struct WebSplitMarkdownScreenTests {
	@Test("Negative TextKit origins round-trip through split scroll synchronization")
	func negativeDocumentOriginScrollGeometryRoundTrips() {
		let frame = CGRect(x: 0, y: -54_700, width: 600, height: 125_000)
		let visibleHeight: CGFloat = 900

		for expected in [0.0, 0.025, 0.5, 0.975, 1.0] {
			let origin = MarkdownScrollGeometry.originY(
				fraction: expected, documentFrame: frame, visibleHeight: visibleHeight)
			let actual = MarkdownScrollGeometry.fraction(
				originY: origin, documentFrame: frame, visibleHeight: visibleHeight)

			#expect(abs(actual - expected) < 0.000_001)
		}
		#expect(MarkdownScrollGeometry.fraction(
			originY: frame.minY, documentFrame: frame,
			visibleHeight: visibleHeight) == 0)
		#expect(MarkdownScrollGeometry.originY(
			fraction: 0, documentFrame: frame,
			visibleHeight: visibleHeight) == frame.minY)
	}

	@Test("Split editing closes scroll sync before the host changes its binding")
	func editClosesScrollSyncBeforeHostUpdate() {
		var syncIsSuspended = false
		var hostObservedSuspendedSync = false

		MarkdownSplitEditRelay.forward(
			"updated",
			caret: 7,
			beginEditing: { syncIsSuspended = true },
			report: { text, caret in
				hostObservedSuspendedSync = syncIsSuspended
				#expect(text == "updated")
				#expect(caret == 7)
			},
			write: { _ in Issue.record("A host edit must not use the binding fallback") })

		#expect(hostObservedSuspendedSync)
	}

	@Test("Binding-backed split editing also closes scroll sync first")
	func bindingEditClosesScrollSyncBeforeWrite() {
		var syncIsSuspended = false
		var writtenText: String?
		var writeObservedSuspendedSync = false

		MarkdownSplitEditRelay.forward(
			"updated",
			caret: nil,
			beginEditing: { syncIsSuspended = true },
			report: nil,
			write: {
				writeObservedSuspendedSync = syncIsSuspended
				writtenText = $0
			})

		#expect(writeObservedSuspendedSync)
		#expect(writtenText == "updated")
	}

	@Test("A source-pane selection handoff does not move focus into the preview")
	func sourceSelectionHandoffKeepsRawEditorFocused() async throws {
		let source = "# Before\n\n{: .callout}\n\nParagraph LOCAL target\n"
		let selected = (source as NSString).range(of: "LOCAL")
		let model = SplitSelectionModel()
		model.target = MarkdownSelectionTarget(range: selected, token: 1)
		let root = SplitSelectionHost(source: source, model: model)
		let hosting = NSHostingView(rootView: root)
		hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
		let window = NSWindow(
			contentRect: hosting.frame, styleMask: [.borderless],
			backing: .buffered, defer: false)
		window.contentView = hosting
		window.orderFront(nil)
		hosting.layoutSubtreeIfNeeded()

		let rawEditor = try #require(try await waitForRawEditor(in: hosting))

		for _ in 0..<80 where rawEditor.selectedRange() != selected {
			hosting.layoutSubtreeIfNeeded()
			try await Task.sleep(for: .milliseconds(25))
		}
		try await Task.sleep(for: .milliseconds(250))

		#expect(rawEditor.selectedRange() == selected)
		#expect(!(window.firstResponder is WKWebView))
	}

	@Test("Split keeps a whole heading selection and both panes at its viewport")
	func splitKeepsWholeHeadingSelectionAndViewport() async throws {
		let source = (0...420).map { index in
			"## Sector \(String(format: "%03d", index))\n\nTransfer sentence \(index)."
		}.joined(separator: "\n\n")
		let selected = (source as NSString).range(of: "## Sector 016")
		let expectedFraction = 0.04
		let model = SplitSelectionModel()
		model.target = MarkdownSelectionTarget(range: selected, token: 1)
		model.scrollTarget = MarkdownScrollTarget(
			topFraction: expectedFraction, token: 1)
		let hosting = NSHostingView(rootView: SplitSelectionHost(source: source, model: model))
		hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
		let window = NSWindow(
			contentRect: hosting.frame, styleMask: [.borderless],
			backing: .buffered, defer: false)
		window.contentView = hosting
		window.orderFront(nil)
		hosting.layoutSubtreeIfNeeded()

		let rawEditor = try #require(try await waitForRawEditor(in: hosting))
		let webView = try #require(try await waitForWebView(in: hosting))
		for _ in 0..<120 where rawEditor.selectedRange() != selected {
			hosting.layoutSubtreeIfNeeded()
			try await Task.sleep(for: .milliseconds(25))
		}
		for _ in 0..<160 {
			hosting.layoutSubtreeIfNeeded()
			let raw = scrollFraction(of: rawEditor)
			let rendered = await webScrollFraction(of: webView)
			if rawEditor.selectedRange() == selected,
			   abs(raw - expectedFraction) <= 0.03,
			   let rendered, abs(rendered - expectedFraction) <= 0.03 { break }
			try await Task.sleep(for: .milliseconds(25))
		}

		let rawFraction = scrollFraction(of: rawEditor)
		let renderedFraction = try #require(await webScrollFraction(of: webView))
		#expect(rawEditor.selectedRange() == selected)
		#expect(abs(rawFraction - renderedFraction) <= 0.03,
			"source=\(rawFraction), rendered=\(renderedFraction)")
		#expect(rawFraction < 0.1,
			"Sector 016 selection was hidden by a stale viewport at \(rawFraction)")
	}

	@Test("A long-lived split view reapplies repeated host scroll targets")
	func splitReappliesHostScrollTargets() async throws {
		let source = (0..<250).map { "Line \($0): enough text to create a scrollable document." }.joined(separator: "\n")
		let model = SplitSelectionModel()
		model.scrollTarget = MarkdownScrollTarget(topFraction: 0.75, token: 1)
		let hosting = NSHostingView(rootView: SplitSelectionHost(source: source, model: model))
		hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
		let window = NSWindow(
			contentRect: hosting.frame, styleMask: [.borderless],
			backing: .buffered, defer: false)
		window.contentView = hosting
		window.orderFront(nil)
		hosting.layoutSubtreeIfNeeded()

		let rawEditor = try #require(try await waitForRawEditor(in: hosting))
		for (token, expected) in [(1, 0.75), (2, 0.2)] {
			if token > 1 {
				// Schedule a delayed resize restore at the previous position,
				// then supersede it with a newer explicit host target.
				window.setContentSize(NSSize(width: 700, height: 400))
				hosting.layoutSubtreeIfNeeded()
				try await Task.sleep(for: .milliseconds(50))
				model.scrollTarget = MarkdownScrollTarget(topFraction: expected, token: token)
			}
			for _ in 0..<80 where abs(scrollFraction(of: rawEditor) - expected) > 0.05 {
				hosting.layoutSubtreeIfNeeded()
				try await Task.sleep(for: .milliseconds(25))
			}
			#expect(
				abs(scrollFraction(of: rawEditor) - expected) <= 0.05,
				"target \(expected), actual \(scrollFraction(of: rawEditor))")
		}
		// The stale resize task has three delayed passes; prove none can
		// resurrect the superseded 0.75 viewport after the immediate assertion.
		try await Task.sleep(for: .milliseconds(1_800))
		#expect(abs(scrollFraction(of: rawEditor) - 0.2) <= 0.05)
	}

	@Test("Split restores a collapsed source selection after large-document layout")
	func splitRestoresCollapsedSourceViewportAfterLateLayout() async throws {
		let source = (0..<1_600).map { index in
			"## Sector \(index)\n\nTransfer sentence \(index) records enough text to make the document scroll."
		}.joined(separator: "\n\n")
		let caret = (source as NSString).range(of: "Sector 800").location
		let model = SplitSelectionModel()
		model.target = MarkdownSelectionTarget(
			range: NSRange(location: caret, length: 0), token: 1)
		model.scrollTarget = MarkdownScrollTarget(topFraction: 0.5, token: 1)
		let hosting = NSHostingView(rootView: SplitSelectionHost(source: source, model: model))
		hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
		let window = NSWindow(
			contentRect: hosting.frame, styleMask: [.borderless],
			backing: .buffered, defer: false)
		window.contentView = hosting
		window.orderFront(nil)
		hosting.layoutSubtreeIfNeeded()

		let rawEditor = try #require(try await waitForRawEditor(in: hosting))
		for _ in 0..<120 where abs(scrollFraction(of: rawEditor) - 0.5) > 0.05 {
			hosting.layoutSubtreeIfNeeded()
			try await Task.sleep(for: .milliseconds(25))
		}

		#expect(rawEditor.selectedRange() == NSRange(location: caret, length: 0))
		#expect(abs(scrollFraction(of: rawEditor) - 0.5) <= 0.05,
			"collapsed handoff settled at \(scrollFraction(of: rawEditor))")
	}

	@Test("Split reapplies its shared viewport after the panes resize")
	func splitReappliesViewportAfterResize() async throws {
		let source = (0..<1_600).map { index in
			"## Sector \(index)\n\nTransfer sentence \(index) records enough text to make the document scroll."
		}.joined(separator: "\n\n")
		let model = SplitSelectionModel()
		model.scrollTarget = MarkdownScrollTarget(topFraction: 0.5, token: 1)
		let hosting = NSHostingView(rootView: SplitSelectionHost(source: source, model: model))
		hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
		let window = NSWindow(
			contentRect: hosting.frame, styleMask: [.borderless],
			backing: .buffered, defer: false)
		window.contentView = hosting
		window.orderFront(nil)
		hosting.layoutSubtreeIfNeeded()

		let rawEditor = try #require(try await waitForRawEditor(in: hosting))
		let webView = try #require(try await waitForWebView(in: hosting))
		try await waitForSplitViewport(
			0.5, rawEditor: rawEditor, webView: webView, hosting: hosting)

		window.setContentSize(NSSize(width: 1_400, height: 700))
		hosting.layoutSubtreeIfNeeded()
		// Let WebKit finish its asynchronous reflow. Without the resize restore,
		// it keeps the old pixel offset and only then exposes the drifted fraction.
		try await Task.sleep(for: .milliseconds(300))
		try await waitForSplitViewport(
			0.5, rawEditor: rawEditor, webView: webView, hosting: hosting)

		let rawFraction = scrollFraction(of: rawEditor)
		let renderedFraction = try #require(await webScrollFraction(of: webView))
		#expect(abs(rawFraction - 0.5) <= 0.05, "resized source settled at \(rawFraction)")
		#expect(abs(renderedFraction - 0.5) <= 0.05,
			"resized preview settled at \(renderedFraction)")

		window.setContentSize(NSSize(width: 600, height: 700))
		hosting.layoutSubtreeIfNeeded()
		try await Task.sleep(for: .milliseconds(800))
		try await waitForSplitViewport(
			0.5, rawEditor: rawEditor, webView: webView, hosting: hosting)

		let narrowedRawFraction = scrollFraction(of: rawEditor)
		let narrowedRenderedFraction = try #require(await webScrollFraction(of: webView))
		#expect(abs(narrowedRawFraction - 0.5) <= 0.05,
			"narrowed source settled at \(narrowedRawFraction)")
		#expect(abs(narrowedRenderedFraction - 0.5) <= 0.05,
			"narrowed preview settled at \(narrowedRenderedFraction)")

		window.setContentSize(NSSize(width: 1_300, height: 700))
		hosting.layoutSubtreeIfNeeded()
		try await Task.sleep(for: .milliseconds(100))
		window.setContentSize(NSSize(width: 750, height: 700))
		hosting.layoutSubtreeIfNeeded()
		try await Task.sleep(for: .milliseconds(1_800))
		try await waitForSplitViewport(
			0.5, rawEditor: rawEditor, webView: webView, hosting: hosting)

		let reversedRawFraction = scrollFraction(of: rawEditor)
		let reversedRenderedFraction = try #require(await webScrollFraction(of: webView))
		#expect(abs(reversedRawFraction - 0.5) <= 0.05,
			"rapidly resized source settled at \(reversedRawFraction)")
		#expect(abs(reversedRenderedFraction - 0.5) <= 0.05,
			"rapidly resized preview settled at \(reversedRenderedFraction)")
	}

	@Test("A small rendered-pane scroll drives the source pane in a long document")
	func smallRenderedScrollDrivesRawPane() async throws {
		let source = (0..<1_600).map { index in
			"## Sector \(index)\n\nTransfer sentence \(index) records enough text to make the document scroll."
		}.joined(separator: "\n\n")
		let model = SplitSelectionModel()
		model.scrollTarget = MarkdownScrollTarget(topFraction: 0.8, token: 1)
		let hosting = NSHostingView(rootView: SplitSelectionHost(source: source, model: model))
		hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
		let window = NSWindow(
			contentRect: hosting.frame, styleMask: [.borderless],
			backing: .buffered, defer: false)
		window.contentView = hosting
		window.orderFront(nil)
		hosting.layoutSubtreeIfNeeded()

		let rawEditor = try #require(try await waitForRawEditor(in: hosting))
		let webView = try #require(try await waitForWebView(in: hosting))
		try await waitForSplitViewport(
			0.8, rawEditor: rawEditor, webView: webView, hosting: hosting)
		// Let the initial WebKit/TextKit reflow restore finish so this assertion
		// isolates an ordinary small user scroll in a settled split view.
		try await Task.sleep(for: .milliseconds(2_000))

		let renderedFraction = try #require(await scrollWebView(webView, byFraction: -0.005))
		for _ in 0..<80 where abs(scrollFraction(of: rawEditor) - renderedFraction) > 0.002 {
			hosting.layoutSubtreeIfNeeded()
			try await Task.sleep(for: .milliseconds(25))
		}

		let rawFraction = scrollFraction(of: rawEditor)
		#expect(abs(rawFraction - renderedFraction) <= 0.002,
			"rendered settled at \(renderedFraction), source stayed at \(rawFraction)")
	}

	private func waitForRawEditor(in view: NSView) async throws -> NSTextView? {
		for _ in 0..<120 {
			if let editor = findRawEditor(in: view) { return editor }
			try await Task.sleep(for: .milliseconds(25))
		}
		return nil
	}

	private func findRawEditor(in view: NSView) -> NSTextView? {
		if let editor = view as? NSTextView { return editor }
		for child in view.subviews {
			if let editor = findRawEditor(in: child) { return editor }
		}
		return nil
	}

	private func waitForWebView(in view: NSView) async throws -> WKWebView? {
		for _ in 0..<120 {
			if let webView = findWebView(in: view) { return webView }
			try await Task.sleep(for: .milliseconds(25))
		}
		return nil
	}

	private func findWebView(in view: NSView) -> WKWebView? {
		if let webView = view as? WKWebView { return webView }
		for child in view.subviews {
			if let webView = findWebView(in: child) { return webView }
		}
		return nil
	}

	private func waitForSplitViewport(
		_ expected: Double,
		rawEditor: NSTextView,
		webView: WKWebView,
		hosting: NSHostingView<SplitSelectionHost>
	) async throws {
		for _ in 0..<160 {
			hosting.layoutSubtreeIfNeeded()
			let raw = scrollFraction(of: rawEditor)
			let rendered = await webScrollFraction(of: webView)
			if abs(raw - expected) <= 0.05,
			   let rendered, abs(rendered - expected) <= 0.05 { return }
			try await Task.sleep(for: .milliseconds(25))
		}
	}

	private func webScrollFraction(of webView: WKWebView) async -> Double? {
		let script = """
		(() => {
		  const root = document.scrollingElement || document.documentElement;
		  const max = Math.max(0, root.scrollHeight - root.clientHeight);
		  return max > 0 ? root.scrollTop / max : 0;
		})()
		"""
		guard let value = try? await webView.evaluateJavaScript(script) else { return nil }
		return (value as? NSNumber)?.doubleValue
	}

	private func scrollWebView(_ webView: WKWebView, byFraction delta: Double) async -> Double? {
		let script = """
		(() => {
		  const root = document.scrollingElement || document.documentElement;
		  const max = Math.max(0, root.scrollHeight - root.clientHeight);
		  root.scrollTop += max * \(delta);
		  const top = max > 0 ? root.scrollTop / max : 0;
		  window.webkit.messageHandlers.mdedit.postMessage({
		    type: 'scroll', y: root.scrollTop, top,
		    visible: Math.min(1, root.clientHeight / root.scrollHeight),
		    content: Math.min(1, root.scrollHeight / root.clientHeight)
		  });
		  return top;
		})()
		"""
		guard let value = try? await webView.evaluateJavaScript(script) else { return nil }
		return (value as? NSNumber)?.doubleValue
	}

	private func scrollFraction(of editor: NSTextView) -> Double {
		guard let scrollView = editor.enclosingScrollView else { return 0 }
		return MarkdownScrollGeometry.fraction(
			originY: scrollView.contentView.bounds.origin.y,
			documentFrame: scrollView.documentView?.frame ?? .zero,
			visibleHeight: scrollView.contentView.bounds.height)
	}
}

@MainActor @Observable
private final class SplitSelectionModel {
	var target: MarkdownSelectionTarget?
	var scrollTarget: MarkdownScrollTarget?
}

private struct SplitSelectionHost: View {
	let source: String
	@Bindable var model: SplitSelectionModel
	@State private var text: String
	@State private var heading: String?

	init(source: String, model: SplitSelectionModel) {
		self.source = source
		self.model = model
		_text = State(initialValue: source)
	}

	var body: some View {
		WebSplitMarkdownScreen(
			text: $text,
			selectedHeadingID: $heading,
			theme: .default,
			fontSize: 14,
			editablePreview: true,
			selectionTargetPane: .source,
			scrollTarget: model.scrollTarget,
			selectionTarget: model.target)
	}
}
#endif
