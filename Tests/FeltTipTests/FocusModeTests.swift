import Foundation
import Testing
@testable import FeltTip
#if os(macOS)
	import AppKit
	import SwiftUI
#endif

@Suite struct FocusModeTests {
	@Test func rawFocusUsesTheParagraphContainingTheCaret() {
		let text = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."
		let caret = (text as NSString).range(of: "Second").location + 3

		let range = MarkdownFocusMode.focusedRange(in: text, selection: NSRange(location: caret, length: 0))

		#expect((text as NSString).substring(with: range) == "Second paragraph.\n")
	}

	@Test func rawFocusIncludesEveryParagraphTouchedByASelection() {
		let text = "One\n\nTwo\n\nThree"
		let start = (text as NSString).range(of: "One").location
		let end = NSMaxRange((text as NSString).range(of: "Two"))

		let range = MarkdownFocusMode.focusedRange(
			in: text,
			selection: NSRange(location: start, length: end - start))

		#expect((text as NSString).substring(with: range) == "One\n\nTwo\n")
	}

	@Test @MainActor func styledFocusCanBeEnabledWithoutForcingARenderReload() {
		let plain = MarkdownWebView(text: "One\n\nTwo", theme: .default, fontSize: 16)
		let focused = plain.focusMode(true)

		#expect(!plain.isFocusModeEnabled)
		#expect(focused.isFocusModeEnabled)
		#expect(plain.makeCoordinator().configSignature() == focused.makeCoordinator().configSignature())
	}

	@Test @MainActor func styledFocusScriptDimsEveryTopLevelBlockExceptTheSelectionBlock() {
		let script = MarkdownWebView.Coordinator.focusModeScript

		#expect(script.contains("window.__mdSetFocusMode"))
		#expect(script.contains("selectionchange"))
		#expect(script.contains("md-focus-active"))
		#expect(script.contains("body.md-focus-mode > :not(.md-focus-active)"))
		#expect(script.contains("opacity: 0.3"))
	}

	#if os(macOS)
	@Test @MainActor func rawEditorDimsUnicodeWithAnOpaqueColorWhileItHasKeyboardFocus() async throws {
		let text = "First\n\n第二"
		let root = RawMarkdownScreen(
			text: .constant(text), selectedHeadingID: .constant(nil), fontSize: 14,
			focusModeEnabled: true, theme: .default)
		let hosting = NSHostingView(rootView: root)
		hosting.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
		let window = NSWindow(
			contentRect: hosting.frame, styleMask: [.borderless],
			backing: .buffered, defer: false)
		defer { closeTestWindow(window) }
		window.contentView = hosting
		window.makeKeyAndOrderFront(nil)
		hosting.layoutSubtreeIfNeeded()

		let textView = try #require(findTextView(in: hosting))
		textView.setSelectedRange(NSRange(location: 0, length: 0))
		window.makeFirstResponder(textView)
		try await Task.sleep(for: .milliseconds(50))
		let dimmed = textView.layoutManager?.temporaryAttribute(
			.foregroundColor, atCharacterIndex: 8, effectiveRange: nil) as? NSColor
		let active = textView.layoutManager?.temporaryAttribute(
			.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) as? NSColor
		// TextKit can drop fallback-font glyphs (including CJK) when a temporary
		// foreground color is translucent. Dim by blending against the page while
		// keeping the actual drawing color opaque.
		#expect(dimmed?.alphaComponent == 1)
		#expect(dimmed != active)

		window.makeFirstResponder(nil)
		try await Task.sleep(for: .milliseconds(50))
		let restored = textView.layoutManager?.temporaryAttribute(
			.foregroundColor, atCharacterIndex: 8, effectiveRange: nil) as? NSColor
		#expect(restored == nil)
	}

	@MainActor private func findTextView(in view: NSView) -> NSTextView? {
		if let textView = view as? NSTextView { return textView }
		return view.subviews.lazy.compactMap(findTextView(in:)).first
	}
	#endif
}
