#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import FeltTip

@MainActor
struct RawEditorInitialCursorTests {
	@Test("Pre-filled raw source starts with the caret at the beginning")
	func prefilledSourceStartsAtBeginning() async throws {
		let source = (0..<20_000).map { "Line \($0)" }.joined(separator: "\n")
		let editor = MarkdownTextEditor(
			text: .constant(source),
			selectedHeadingID: .constant(nil)
		)
		.environment(\.showLineNumbers, true)
		.environment(\.syntaxHighlightingEnabled, true)
		let hostingView = NSHostingView(rootView: editor)
		hostingView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
		hostingView.layoutSubtreeIfNeeded()

		var textView: NSTextView?
		for _ in 0..<40 where textView == nil {
			textView = findTextView(in: hostingView)
			if textView == nil { try await Task.sleep(for: .milliseconds(25)) }
		}
		let raw = try #require(textView)
		try await Task.sleep(for: .seconds(1))
		#expect(raw.selectedRange() == NSRange(location: 0, length: 0))
		let scrollView = try #require(raw.enclosingScrollView)
		#expect(scrollView.contentView.bounds.origin.y <= 1)
	}

	@Test("Raw source disables syntax-corrupting text substitutions")
	func rawSourceIsSourceFaithful() async throws {
		let editor = MarkdownTextEditor(
			text: .constant("|---|---|\n"),
			selectedHeadingID: .constant(nil)
		)
		let hostingView = NSHostingView(rootView: editor)
		hostingView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
		hostingView.layoutSubtreeIfNeeded()

		var textView: NSTextView?
		for _ in 0..<40 where textView == nil {
			textView = findTextView(in: hostingView)
			if textView == nil { try await Task.sleep(for: .milliseconds(25)) }
		}
		let raw = try #require(textView)
		#expect(!raw.isAutomaticDashSubstitutionEnabled)
		#expect(!raw.isAutomaticQuoteSubstitutionEnabled)
		#expect(!raw.isAutomaticTextReplacementEnabled)
		#expect(!raw.isAutomaticSpellingCorrectionEnabled)
	}

	@Test("Initial cursor report uses the populated line index")
	func initialCursorMatchesNativeSelection() async throws {
		let source = "# Heading\n\nsecond line\n"
		var reports: [(Int, Int, Int)] = []
		let editor = MarkdownTextEditor(
			text: .constant(source),
			selectedHeadingID: .constant(nil),
			onCursorPositionChanged: { line, column, _, offset in
				reports.append((line, column, offset))
			}
		)
		let hostingView = NSHostingView(rootView: editor)
		hostingView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
		hostingView.layoutSubtreeIfNeeded()

		var textView: NSTextView?
		for _ in 0..<40 where textView == nil {
			textView = findTextView(in: hostingView)
			if textView == nil { try await Task.sleep(for: .milliseconds(25)) }
		}
		let raw = try #require(textView)
		let offset = raw.selectedRange().location
		let expected = MarkdownLineIndex(text: source).position(at: offset)
		for _ in 0..<40 where reports.last?.0 != expected.line || reports.last?.1 != expected.column {
			try await Task.sleep(for: .milliseconds(25))
		}
		#expect(reports.last?.0 == expected.line)
		#expect(reports.last?.1 == expected.column)
		#expect(reports.last?.2 == offset)
	}

	private func findTextView(in view: NSView) -> NSTextView? {
		if let textView = view as? NSTextView { return textView }
		return view.subviews.lazy.compactMap(findTextView(in:)).first
	}
}
#endif
