#if os(macOS)
#if os(macOS)
	import AppKit
#else
	import UIKit
#endif
import SwiftUI
import Testing
@testable import FeltTip

@MainActor
@Suite(.serialized)
struct MarkdownTextEditorFindTests {
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
		window.contentView = hostingView
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

		_ = try await waitForSearchField(in: hostingView)
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

	private func waitUntil(
		_ description: String,
		condition: () -> Bool
	) async throws {
		for _ in 0..<100 {
			if condition() {
				return
			}
			try await Task.sleep(for: .milliseconds(10))
		}
		Issue.record("Timed out waiting for \(description)")
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
#endif
