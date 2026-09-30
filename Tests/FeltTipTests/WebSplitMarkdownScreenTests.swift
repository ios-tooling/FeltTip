#if os(macOS)
import AppKit
import Observation
import SwiftUI
import Testing
import WebKit
@testable import FeltTip

@MainActor
struct WebSplitMarkdownScreenTests {
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
}

@MainActor @Observable
private final class SplitSelectionModel {
	var target: MarkdownSelectionTarget?
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
			selectionTarget: model.target)
	}
}
#endif
