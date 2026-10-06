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

	@Test("A delayed rendered zero cannot override an in-flight host restore")
	func delayedRenderedZeroStaysInsideHostRestoreGate() {
		var gate = MarkdownSplitHostRestoreGuard()
		gate.begin(at: 0.5)

		let consumedStaleReport = gate.consumeRenderedReport(0)
		#expect(consumedStaleReport)
		#expect(gate.target == 0.5)
		let consumedSettledReport = gate.consumeRenderedReport(0.46)
		#expect(consumedSettledReport)
		#expect(gate.target == nil)
		let consumedPostSettlementReport = gate.consumeRenderedReport(0)
		#expect(!consumedPostSettlementReport)
	}

	@Test("Cancelling a host restore immediately releases rendered reports")
	func cancelledHostRestoreReleasesRenderedReports() {
		var gate = MarkdownSplitHostRestoreGuard()
		gate.begin(at: 0.5)
		gate.cancel()

		let consumedCancelledReport = gate.consumeRenderedReport(0.2)
		#expect(!consumedCancelledReport)
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
