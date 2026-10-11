#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import FeltTip

/// The raw editor on TextKit 2 with documents far past what TextKit 1 could
/// open. These drive a real window and check rendered pixels, not just
/// geometry: the TextKit 2 failure mode was a correct caret over a blank view.
///
/// The default size keeps the suite fast. Set `FELTTIP_LARGE_DOC_MB` (for
/// example `1,5,20`) to also time and exercise those sizes.
@Suite(.serialized) @MainActor struct RawEditorLargeDocumentTests {
	@Test("A large raw document opens, jumps to its end, pages and drags without blank viewports")
	func largeDocumentNavigatesWithoutBlankViewports() async throws {
		let sizes = ProcessInfo.processInfo.environment["FELTTIP_LARGE_DOC_MB"]?
			.split(separator: ",").compactMap { Double($0) } ?? [2]
		for megabytes in sizes {
			try await exercise(megabytes: megabytes)
		}
	}

	private func exercise(megabytes: Double) async throws {
		let source = Self.document(bytes: Int(megabytes * 1_048_576))
		let lineCount = MarkdownLineIndex(text: source).starts.count
		var text = source
		var heading: String?
		let start = ContinuousClock.now
		let root = RawMarkdownScreen(
			text: Binding(get: { text }, set: { text = $0 }),
			selectedHeadingID: Binding(get: { heading }, set: { heading = $0 }),
			fontSize: 13, theme: .default)
			.environment(\.showLineNumbers, true)
			.environment(\.syntaxHighlightingEnabled, true)
		let hosting = NSHostingView(rootView: root)
		hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
		let window = NSWindow(
			contentRect: hosting.frame, styleMask: [.titled],
			backing: .buffered, defer: false)
		defer { closeTestWindow(window) }
		window.contentView = hosting
		window.makeKeyAndOrderFront(nil)
		hosting.layoutSubtreeIfNeeded()

		var found: NSTextView?
		for _ in 0..<400 where found == nil {
			found = findTextView(in: hosting)
			if found == nil { try await Task.sleep(for: .milliseconds(10)) }
		}
		let textView = try #require(found)
		let scrollView = try #require(textView.enclosingScrollView)
		window.displayIfNeeded()
		let openTime = ContinuousClock.now - start
		// Let the mount turn finish (its queued initial-caret reveal included),
		// as it always has before a person can press a key.
		try await settle(window)
		let label = String(format: "%.0f MB", megabytes)
		print("[LargeDoc] \(label): \(lineCount) lines, open+first draw \(openTime)")

		#expect(textView.textLayoutManager != nil, "\(label): editor fell back to TextKit 1")
		#expect(scrollView.contentView.bounds.minY <= 1, "\(label): did not open at the top")
		#expect(try inkedRows(in: textView) > 20, "\(label): blank viewport after open")
		#expect(try rulerInkedRows(scrollView) > 20, "\(label): no line numbers after open")

		// ⌘↓ — the reported blank-viewport repro.
		window.makeFirstResponder(textView)
		let jumpStart = ContinuousClock.now
		textView.doCommand(by: #selector(NSResponder.moveToEndOfDocument(_:)))
		try await settle(window)
		// Give a slow jump (see the TextKit 2 note at the top-typing check)
		// time to finish before judging where it landed.
		for _ in 0..<100 where !caretIsVisible(textView, scrollView) {
			try await Task.sleep(for: .milliseconds(50))
			window.displayIfNeeded()
		}
		print("[LargeDoc] \(label): ⌘↓ settled in \(ContinuousClock.now - jumpStart)")
		let length = textView.textStorage?.length ?? 0
		#expect(textView.selectedRange().location == length, "\(label): caret is not at the end")
		#expect(caretIsVisible(textView, scrollView), "\(label): caret at the end is offscreen")
		#expect(try inkedRows(in: textView) > 5, "\(label): blank viewport after ⌘↓")
		#expect(try rulerInkedRows(scrollView) > 5, "\(label): no line numbers after ⌘↓")
		let endLine = topLine(textView, scrollView)
		#expect(endLine > lineCount - 80, "\(label): top line \(endLine) is not near the end (\(lineCount))")
		// Only the viewport may be laid out. Full layout makes every later edit
		// shift every fragment after it (seconds per keystroke near the top).
		let laidOutAfterJump = laidOutFragments(textView)
		print("[LargeDoc] \(label): \(laidOutAfterJump) fragments laid out after ⌘↓")
		if megabytes < 19 {
			#expect(laidOutAfterJump < 5_000, "\(label): ⌘↓ laid out \(laidOutAfterJump) fragments")
		}

		// ⌘↑ back to the top.
		textView.doCommand(by: #selector(NSResponder.moveToBeginningOfDocument(_:)))
		try await settle(window)
		#expect(topLine(textView, scrollView) <= 1, "\(label): ⌘↑ did not return to the top")
		#expect(try inkedRows(in: textView) > 20, "\(label): blank viewport after ⌘↑")

		// Page down a few times: each page advances and draws.
		var previous = topLine(textView, scrollView)
		for page in 1...3 {
			textView.doCommand(by: #selector(NSResponder.pageDown(_:)))
			try await settle(window)
			let line = topLine(textView, scrollView)
			#expect(line > previous, "\(label): page \(page) did not advance (\(previous) → \(line))")
			#expect(try inkedRows(in: textView) > 20, "\(label): blank viewport after page \(page)")
			previous = line
		}

		// A scroller drag lands the clip view at an arbitrary pixel offset
		// deep in the estimated height; it must draw there and stay there.
		for fraction in [0.37, 0.81, 0.5] {
			let documentHeight = scrollView.documentView?.frame.height ?? 0
			let y = (documentHeight - scrollView.contentView.bounds.height) * fraction
			NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
			scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.minX, y: y))
			scrollView.reflectScrolledClipView(scrollView.contentView)
			NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
			try await settle(window)
			let line = topLine(textView, scrollView)
			let expected = Int(Double(lineCount) * fraction)
			#expect(abs(line - expected) < max(200, lineCount / 10),
				"\(label): drag to \(fraction) shows line \(line), expected about \(expected)")
			#expect(try inkedRows(in: textView) > 20, "\(label): blank viewport after drag to \(fraction)")
			#expect(try rulerInkedRows(scrollView) > 20, "\(label): no line numbers after drag to \(fraction)")
			try await Task.sleep(for: .milliseconds(600))  // past the geometry window
			#expect(abs(topLine(textView, scrollView) - line) <= 2,
				"\(label): viewport drifted after drag to \(fraction)")
		}

		#expect(laidOutFragments(textView) < 20_000,
			"\(label): navigation laid out \(laidOutFragments(textView)) fragments")

		// Typing near the top stays responsive after visiting the end.
		textView.doCommand(by: #selector(NSResponder.moveToBeginningOfDocument(_:)))
		try await settle(window)
		let topTypingStart = ContinuousClock.now
		for character in "top" { textView.insertText(String(character), replacementRange: textView.selectedRange()) }
		window.displayIfNeeded()
		let topTypingTime = ContinuousClock.now - topTypingStart
		print("[LargeDoc] \(label): 3 keystrokes at the top \(topTypingTime)")
		// From roughly 19.5 MB of this content, a plain TextKit 2 NSTextView —
		// no editor code involved — makes every edit near the top cost seconds
		// once the end of the document has been laid out; its height estimate
		// also pins at the view's 10,000,000-point ceiling around there. That is
		// AppKit's limit, not this editor's, so only smaller documents assert.
		if megabytes < 19 {
			#expect(topTypingTime < .seconds(1.5), "\(label): typing at the top took \(topTypingTime)")
		}

		// Typing at the end of the document stays responsive.
		textView.doCommand(by: #selector(NSResponder.moveToEndOfDocument(_:)))
		try await settle(window)
		let typingStart = ContinuousClock.now
		for character in "typed" { textView.insertText(String(character), replacementRange: textView.selectedRange()) }
		window.displayIfNeeded()
		let typingTime = ContinuousClock.now - typingStart
		print("[LargeDoc] \(label): 5 keystrokes at EOF \(typingTime)")
		#expect(typingTime < .seconds(2.5), "\(label): typing at the end took \(typingTime)")
		#expect(textView.string.hasSuffix("typed"))
		#expect(textView.textLayoutManager != nil, "\(label): editing fell back to TextKit 1")
	}

	// MARK: Plumbing

	static func document(bytes: Int) -> String {
		let paragraph = "Paragraph with **bold**, *italic*, `code` and a [link](https://example.com) in line form.\n"
		var parts: [String] = []
		var size = 0
		var section = 0
		while size < bytes {
			section += 1
			let block = "\n## Section \(section)\n\n" + String(repeating: paragraph, count: 6)
				+ "- item one\n- item two\n\n> quoted\n\n```swift\nlet x = \(section)\n```\n"
			parts.append(block)
			size += block.utf8.count
		}
		parts.append("\nFinal line marker\n")
		return parts.joined()
	}

	private func laidOutFragments(_ textView: NSTextView) -> Int {
		guard let manager = textView.textLayoutManager else { return 0 }
		var count = 0
		manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: []) { fragment in
			if fragment.state == .layoutAvailable { count += 1 }
			return true
		}
		return count
	}

	private func settle(_ window: NSWindow) async throws {
		for _ in 0..<6 {
			window.displayIfNeeded()
			try await Task.sleep(for: .milliseconds(30))
		}
	}

	private func topLine(_ textView: NSTextView, _ scrollView: NSScrollView) -> Int {
		let clip = scrollView.contentView
		let top = clip.convert(CGPoint(x: clip.bounds.minX, y: clip.bounds.minY + 4), to: textView)
		let offset = textView.sourceCharacterOffset(
			at: CGPoint(x: textView.textContainerOrigin.x, y: max(textView.textContainerOrigin.y, top.y))) ?? 0
		return MarkdownLineIndex(text: textView.string).position(at: offset).line
	}

	private func caretIsVisible(_ textView: NSTextView, _ scrollView: NSScrollView) -> Bool {
		guard let rect = textView.sourceLineRect(atCharacterOffset: textView.selectedRange().location) else { return false }
		return scrollView.contentView.bounds.intersects(textView.convert(rect, to: scrollView.contentView))
	}

	/// Rows of the visible text area holding anything other than background.
	private func inkedRows(in textView: NSTextView) throws -> Int {
		try inkedRows(of: textView, in: textView.visibleRect, background: textView.backgroundColor)
	}

	private func rulerInkedRows(_ scrollView: NSScrollView) throws -> Int {
		let ruler = try #require(scrollView.verticalRulerView)
		return try inkedRows(of: ruler, in: ruler.bounds, background: nil)
	}

	private func inkedRows(of view: NSView, in rect: NSRect, background: NSColor?) throws -> Int {
		let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: rect))
		view.cacheDisplay(in: rect, to: bitmap)
		let reference = (background ?? bitmap.colorAt(x: 0, y: 0) ?? .white).usingColorSpace(.deviceRGB) ?? .white
		var rows = 0
		for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
			for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
				guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
				let delta = abs(c.redComponent - reference.redComponent)
					+ abs(c.greenComponent - reference.greenComponent)
					+ abs(c.blueComponent - reference.blueComponent)
				if delta > 0.3 { rows += 1; break }
			}
		}
		return rows
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
