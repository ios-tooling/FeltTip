#if os(macOS)
#if os(macOS)
	import AppKit
#else
	import UIKit
#endif
import SwiftUI
import Testing
import WebKit
@testable import FeltTip

@MainActor
@Suite(.serialized)
struct MarkdownTextEditorFindTests {
	@Test
	func guardedNativeReplaceDoesNotEnterBlockingTextFinderPreflight() {
		let editor = FindPreflightRecordingTextView()
		editor.string = "draft"
		editor.setSelectedRange(NSRange(location: 0, length: 5))
		let searchField = NSSearchField()
		searchField.stringValue = "draft"
		let replacementField = NSTextField()
		replacementField.stringValue = "review"
		let control = NSSegmentedControl(
			labels: ["Replace", "All"],
			trackingMode: .selectOne,
			target: nil,
			action: nil)
		control.selectedSegment = 0
		let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
		contentView.addSubview(editor)
		contentView.addSubview(searchField)
		contentView.addSubview(replacementField)
		contentView.addSubview(control)
		let window = NSWindow(
			contentRect: contentView.frame,
			styleMask: [.borderless],
			backing: .buffered,
			defer: false)
		defer { closeTestWindow(window) }
		window.contentView = contentView
		let proxy = NativeReplaceControlProxy(
			editor: editor,
			control: control,
			originalTarget: nil,
			originalAction: nil)

		proxy.performAction(control)

		#expect(editor.string == "review")
		#expect(editor.didEnterTextChangePreflight == false)
	}

	@Test
	func nativeReplaceAllForwardsTheSegmentedControlSender() {
		let editor = MarkdownFormattingTextView()
		let control = NSSegmentedControl(
			labels: ["Replace", "All"],
			trackingMode: .selectOne,
			target: nil,
			action: nil)
		control.selectedSegment = 1
		let target = ReplaceActionRecorder()
		let proxy = NativeReplaceControlProxy(
			editor: editor,
			control: control,
			originalTarget: target,
			originalAction: #selector(ReplaceActionRecorder.record(_:)))

		proxy.performAction(control)

		#expect(target.sender === control)
	}

	@Test
	func findReopenAfterHostUndoSelectsTheRestoredMatchForReplacement() async throws {
		let original = "- [ ] draft item\n"
		let replacement = "- [ ] review item\n"
		let model = MarkdownTextEditorFindModel(text: original)
		let hostingView = NSHostingView(rootView: MarkdownTextEditorFindHost(model: model))
		hostingView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
		let window = NSWindow(
			contentRect: hostingView.frame,
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		defer { closeTestWindow(window) }
		window.contentView = hostingView
		window.orderFront(nil)

		let rawEditor = try await waitForTextView(in: hostingView)
		let findPasteboard = NSPasteboard(name: .find)
		let previousFindString = findPasteboard.string(forType: .string)
		defer {
			findPasteboard.clearContents()
			if let previousFindString {
				findPasteboard.setString(previousFindString, forType: .string)
			}
		}
		findPasteboard.clearContents()
		findPasteboard.setString("draft", forType: .string)

		window.makeFirstResponder(rawEditor)
		perform(.showReplaceInterface, on: rawEditor)
		let replaceField = try await waitForReplaceField(in: hostingView)
		replaceField.stringValue = "review"
		perform(.nextMatch, on: rawEditor)
		let match = (original as NSString).range(of: "draft")
		try await waitUntil("find selects the original match") {
			rawEditor.selectedRange() == match
		}
		perform(.replaceAndFind, on: rawEditor)
		try await waitUntil("first replacement reaches the host") {
			model.text == replacement
		}

		perform(.hideFindInterface, on: rawEditor)
		try await waitUntil("find bar closes") {
			rawEditor.enclosingScrollView?.isFindBarVisible == false
		}
		try await Task.sleep(for: .milliseconds(100))
		model.text = original
		try await waitUntil("host undo reaches the raw editor") {
			rawEditor.string == original
		}
		try await Task.sleep(for: .milliseconds(100))
		rawEditor.setSelectedRange(NSRange(location: (original as NSString).length, length: 0))

		window.makeFirstResponder(rawEditor)
		perform(.showFindInterface, on: rawEditor)
		let reopenedSearchField = try await waitForSearchField(in: hostingView)
		try await waitUntil("find bar reopens") {
			rawEditor.enclosingScrollView?.isFindBarVisible == true
		}
		#expect(reopenedSearchField.stringValue == "draft")
		try await waitUntil("reopened replace bar selects the restored match") {
			rawEditor.selectedRange() == match
		}
		#expect((rawEditor.string as NSString).substring(with: rawEditor.selectedRange()) == "draft")

		// The native Replace button can still arrive with only a caret even
		// though its count says there is a match. Verify the action itself is
		// guarded, including the wrap from end-of-file used by the live repro.
		rawEditor.setSelectedRange(NSRange(location: (original as NSString).length, length: 0))
		perform(.showReplaceInterface, on: rawEditor)
		let reopenedReplaceField = try await waitForReplaceField(in: hostingView)
		reopenedReplaceField.stringValue = "review"
		let replaceControl = try await waitForReplaceControl(in: hostingView)
		replaceControl.setSelected(true, forSegment: 0)
		trigger(replaceControl, segment: 0)
		try await waitUntil("replacement after undo reaches the host") {
			model.text != original
		}
		#expect(model.text == replacement)
	}

	@Test
	func hostDrivenTextChangesRefreshAnOpenIncrementalFindBar() async throws {
		let model = MarkdownTextEditorFindModel(text: "After palette switch")
		let hostingView = NSHostingView(rootView: MarkdownTextEditorFindHost(model: model))
		hostingView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
		let window = NSWindow(
			contentRect: hostingView.frame,
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		defer { closeTestWindow(window) }
		window.contentView = hostingView
		window.orderFront(nil)

		var textView: NSTextView?
		for _ in 0..<160 where textView == nil {
			textView = findTextView(in: hostingView)
			if textView == nil {
				try await Task.sleep(for: .milliseconds(25))
			}
		}
		let rawEditor = try #require(textView)
		window.makeFirstResponder(rawEditor)
		perform(.showReplaceInterface, on: rawEditor)

		let searchField = try await waitForSearchField(in: hostingView)
		#expect(findReplaceField(in: hostingView) != nil)
		let findPasteboard = NSPasteboard(name: .find)
		let previousFindString = findPasteboard.string(forType: .string)
		defer {
			findPasteboard.clearContents()
			if let previousFindString {
				findPasteboard.setString(previousFindString, forType: .string)
			}
		}
		findPasteboard.clearContents()
		findPasteboard.setString("theme", forType: .string)
		window.makeFirstResponder(rawEditor)
		perform(.nextMatch, on: rawEditor)
		try await waitUntil("find field receives the requested query") {
			searchField.stringValue == "theme"
		}
		try await Task.sleep(for: .milliseconds(150))
		#expect(rawEditor.selectedRange().length == 0)

		model.text = "After theme switch"
		try await waitUntil("host text reaches the raw editor") {
			rawEditor.string == model.text
		}
		let match = (model.text as NSString).range(of: "theme")
		try await waitUntil("open find bar selects the restored match") {
			rawEditor.selectedRange() == match
		}
		#expect(findReplaceField(in: hostingView) != nil)
		// The editor refreshes the open bar on a 100 ms delay. The selection
		// can settle before that fires, so outlive it and tear the window down
		// inside the test rather than during process exit.
		try await Task.sleep(for: .milliseconds(250))
		window.orderOut(nil)
		window.contentView = nil
		await Task.yield()
	}

	@Test
	func rawEditorUsesTheIncrementalNativeFindBar() async throws {
		let original = "First run: 83.632438016 seconds. Second run: 83.999 seconds."
		var text = original
		var selectedHeadingID: String?
		let editor = MarkdownTextEditor(
			text: Binding(get: { text }, set: { text = $0 }),
			selectedHeadingID: Binding(
				get: { selectedHeadingID },
				set: { selectedHeadingID = $0 }
			)
		)
		let hostingView = NSHostingView(rootView: editor)
		hostingView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
		let window = NSWindow(
			contentRect: hostingView.frame,
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		defer { closeTestWindow(window) }
		let root = NSView(frame: hostingView.frame)
		let prewarmedEditor = MarkdownWebViewFindHost(webView: WKWebView())
		prewarmedEditor.frame = root.bounds
		prewarmedEditor.isInactive = true
		root.addSubview(prewarmedEditor)
		root.addSubview(hostingView)
		window.contentView = root
		window.orderFront(nil)

		var textView: NSTextView?
		// SwiftUI view installation can be delayed while the WebKit integration
		// suites are running in parallel; keep this bounded but load-tolerant.
		for _ in 0..<160 where textView == nil {
			textView = findTextView(in: hostingView)
			if textView == nil {
				try await Task.sleep(for: .milliseconds(25))
			}
		}

		let rawEditor = try #require(textView)
		#expect(rawEditor.usesFindBar)
		#expect(rawEditor.isIncrementalSearchingEnabled)

		window.makeFirstResponder(rawEditor)
		let showFind = NSMenuItem()
		showFind.tag = NSTextFinder.Action.showFindInterface.rawValue
		rawEditor.performTextFinderAction(showFind)

		let searchField = try await waitForSearchField(in: hostingView)
		let findPasteboard = NSPasteboard(name: .find)
		let previousFindString = findPasteboard.string(forType: .string)
		defer {
			findPasteboard.clearContents()
			if let previousFindString {
				findPasteboard.setString(previousFindString, forType: .string)
			}
		}
		findPasteboard.clearContents()
		findPasteboard.setString("83", forType: .string)
		window.makeFirstResponder(rawEditor)
		perform(.nextMatch, on: rawEditor)

		let source = original as NSString
		let firstRange = source.range(of: "83")
		let secondRange = source.range(
			of: "83",
			range: NSRange(location: firstRange.upperBound, length: source.length - firstRange.upperBound)
		)
		try await waitUntil("raw find selects the first numeric match") {
			rawEditor.selectedRange() == firstRange
		}
		#expect((rawEditor.string as NSString).substring(with: rawEditor.selectedRange()) == "83")

		perform(.nextMatch, on: rawEditor)
		try await waitUntil("raw find selects the next numeric match") {
			rawEditor.selectedRange() == secondRange
		}
		perform(.previousMatch, on: rawEditor)
		try await waitUntil("raw find returns to the previous numeric match") {
			rawEditor.selectedRange() == firstRange
		}
		#expect(rawEditor.string == original)

		try #require(window.makeFirstResponder(searchField))
		let escape = try #require(NSEvent.keyEvent(
			with: .keyDown,
			location: .zero,
			modifierFlags: [],
			timestamp: 0,
			windowNumber: window.windowNumber,
			context: nil,
			characters: "\u{1b}",
			charactersIgnoringModifiers: "\u{1b}",
			isARepeat: false,
			keyCode: 53
		))
		window.sendEvent(escape)
		try await waitUntil("raw find bar dismissal") {
			rawEditor.enclosingScrollView?.isFindBarVisible == false
		}
		try await Task.sleep(for: .milliseconds(500))
		#expect(window.firstResponder === rawEditor)
		#expect(rawEditor.selectedRange() == firstRange)
	}

	@Test
	func nativeFindReportsItsSelectionWhileTheSearchFieldHasFocus() async throws {
		let original = "Before needle after"
		var text = original
		var selectedHeadingID: String?
		var reportedSelection: NSRange?
		let parent = MarkdownTextEditor(
			text: Binding(get: { text }, set: { text = $0 }),
			selectedHeadingID: Binding(
				get: { selectedHeadingID },
				set: { selectedHeadingID = $0 }
			),
			onSourceSelectionChanged: { reportedSelection = $0 }
		)
		let coordinator = MarkdownTextEditor.Coordinator(parent)
		let rawEditor = MarkdownFormattingTextView()
		rawEditor.string = original
		rawEditor.delegate = coordinator
		rawEditor.usesFindBar = true
		let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
		scrollView.documentView = rawEditor
		let window = NSWindow(
			contentRect: scrollView.frame,
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		defer { closeTestWindow(window) }
		window.contentView = scrollView
		window.orderFront(nil)

		try #require(window.makeFirstResponder(rawEditor))
		perform(.showFindInterface, on: rawEditor)
		let searchField = try await waitForSearchField(in: scrollView)
		try #require(window.makeFirstResponder(searchField))
		let match = (original as NSString).range(of: "needle")
		reportedSelection = nil
		rawEditor.setSelectedRange(match)
		coordinator.textViewDidChangeSelection(
			Notification(name: NSTextView.didChangeSelectionNotification, object: rawEditor)
		)

		#expect(window.firstResponder !== rawEditor)
		#expect(scrollView.isFindBarVisible)
		#expect(reportedSelection == match)
	}

	/// Deliver a find-bar control's action the way its click would, without
	/// `performClick`. NSSegmentedCell's click queues a CFRunLoopStop block on
	/// the main run loop for its own nested event loop to consume; when that
	/// loop returns early the block fires later inside the test host's main
	/// `CFRunLoopRun`, which exits the process with status 0 mid-run and loses
	/// the buffered test output. That is what made this suite look like it
	/// passed while silently ending every full `swift test` run.
	private func trigger(_ control: NSSegmentedControl, segment: Int) {
		guard let action = control.action else { return }
		// Momentary controls only update `selectedSegment` on a real click.
		control.selectedSegment = segment
		if let target = control.target as? NSObject {
			_ = target.perform(action, with: control)
		} else {
			_ = control.sendAction(action, to: nil)
		}
	}

	private func perform(_ action: NSTextFinder.Action, on textView: NSTextView) {
		let item = NSMenuItem()
		item.tag = action.rawValue
		textView.performTextFinderAction(item)
	}

	private func findTextView(in view: NSView) -> NSTextView? {
		if let textView = view as? NSTextView {
			return textView
		}
		return view.subviews.lazy.compactMap(findTextView(in:)).first
	}

	private func findSearchField(in view: NSView) -> NSSearchField? {
		if let searchField = view as? NSSearchField {
			return searchField
		}
		return view.subviews.lazy.compactMap(findSearchField(in:)).first
	}

	private func findReplaceField(in view: NSView) -> NSTextField? {
		if let field = view as? NSTextField,
		   !(field is NSSearchField),
		   field.isEditable {
			return field
		}
		return view.subviews.lazy.compactMap(findReplaceField(in:)).first
	}

	private func waitForSearchField(in view: NSView) async throws -> NSSearchField {
		for _ in 0..<100 {
			if let searchField = findSearchField(in: view) {
				return searchField
			}
			try await Task.sleep(for: .milliseconds(10))
		}
		Issue.record("Timed out waiting for the native find bar")
		throw CancellationError()
	}

	private func waitForTextView(in view: NSView) async throws -> NSTextView {
		for _ in 0..<160 {
			if let textView = findTextView(in: view) {
				return textView
			}
			try await Task.sleep(for: .milliseconds(25))
		}
		Issue.record("Timed out waiting for the raw editor")
		throw CancellationError()
	}

	private func waitForReplaceField(in view: NSView) async throws -> NSTextField {
		for _ in 0..<100 {
			if let field = findReplaceField(in: view) {
				return field
			}
			try await Task.sleep(for: .milliseconds(10))
		}
		Issue.record("Timed out waiting for the native replace field")
		throw CancellationError()
	}

	private func waitForReplaceControl(in view: NSView) async throws -> NSSegmentedControl {
		for _ in 0..<100 {
			if let control = findReplaceControl(in: view) {
				return control
			}
			try await Task.sleep(for: .milliseconds(10))
		}
		Issue.record("Timed out waiting for the native Replace/All control")
		throw CancellationError()
	}

	private func findReplaceControl(in view: NSView) -> NSSegmentedControl? {
		guard let field = findReplaceField(in: view) else { return nil }
		let fieldMidY = field.convert(field.bounds, to: nil).midY
		return segmentedControls(in: view).min {
			abs($0.convert($0.bounds, to: nil).midY - fieldMidY) <
				abs($1.convert($1.bounds, to: nil).midY - fieldMidY)
		}
	}

	private func segmentedControls(in view: NSView) -> [NSSegmentedControl] {
		var matches = view.subviews.flatMap(segmentedControls(in:))
		if let control = view as? NSSegmentedControl, control.segmentCount == 2 {
			matches.insert(control, at: 0)
		}
		return matches
	}

	private func waitUntil(
		_ description: String,
		condition: () -> Bool
	) async throws {
		// The full suite runs many WebKit integration tests in parallel. Give
		// main-actor view propagation enough headroom under that load while still
		// putting a firm bound on a genuinely lost update.
		for _ in 0..<500 {
			if condition() {
				return
			}
			try await Task.sleep(for: .milliseconds(10))
		}
		Issue.record("Timed out waiting for \(description)")
		throw CancellationError()
	}
}

@MainActor
private final class FindPreflightRecordingTextView: MarkdownFormattingTextView {
	private(set) var didEnterTextChangePreflight = false

	override func shouldChangeText(
		in affectedCharRange: NSRange,
		replacementString: String?
	) -> Bool {
		didEnterTextChangePreflight = true
		return super.shouldChangeText(
			in: affectedCharRange,
			replacementString: replacementString)
	}
}

@MainActor
private final class MarkdownTextEditorFindModel: ObservableObject {
	@Published var text: String

	init(text: String) {
		self.text = text
	}
}

private struct MarkdownTextEditorFindHost: View {
	@ObservedObject var model: MarkdownTextEditorFindModel
	@State private var selectedHeadingID: String?

	var body: some View {
		MarkdownTextEditor(
			text: $model.text,
			selectedHeadingID: $selectedHeadingID
		)
	}
}

@MainActor
private final class ReplaceActionRecorder: NSObject {
	private(set) weak var sender: AnyObject?

	@objc func record(_ sender: AnyObject?) {
		self.sender = sender
	}
}
#endif
