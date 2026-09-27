#if os(macOS)
import AppKit
import Testing
@testable import FeltTip

/// The raw pane colors markdown *markup* and leaves the prose between markers
/// in the body color, so the source stays readable as text. Links are the one
/// deliberate exception: their text and URL take the link color.
@Suite struct MarkdownSyntaxHighlighterColorTests {

	@MainActor
	private func highlighted(_ source: String) -> NSTextView {
		let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
		let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
		tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
		tv.string = source
		scroll.documentView = tv
		MarkdownSyntaxHighlighter.highlight(textView: tv, theme: .default)
		return tv
	}

	/// True when the highlighter painted a color over the first character of `substring`.
	@MainActor
	private func isColored(_ substring: String, in tv: NSTextView, occurrence: Int = 0) -> Bool {
		let ns = tv.string as NSString
		var search = NSRange(location: 0, length: ns.length)
		var found = ns.range(of: substring, range: search)
		for _ in 0..<occurrence {
			search = NSRange(location: NSMaxRange(found), length: ns.length - NSMaxRange(found))
			found = ns.range(of: substring, range: search)
		}
		return tv.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: found.location, effectiveRange: nil) != nil
	}

	@Test @MainActor
	func headingColorsMarkerOnly() {
		let tv = highlighted("## Title")
		#expect(isColored("##", in: tv))
		#expect(!isColored("Title", in: tv))
	}

	@Test @MainActor
	func emphasisColorsDelimitersOnly() {
		let tv = highlighted("a **bold** and *slant* word")
		#expect(isColored("**", in: tv))
		#expect(isColored("**", in: tv, occurrence: 1))
		#expect(!isColored("bold", in: tv))
		#expect(isColored("*s", in: tv))
		#expect(!isColored("slant", in: tv))
	}

	@Test @MainActor
	func inlineCodeColorsBackticksOnly() {
		let tv = highlighted("run `make` now")
		#expect(isColored("`", in: tv))
		#expect(!isColored("make", in: tv))
		#expect(isColored("`", in: tv, occurrence: 1))
	}

	@Test @MainActor
	func blockquoteColorsMarkerOnly() {
		let tv = highlighted("> quoted words")
		#expect(isColored(">", in: tv))
		#expect(!isColored("quoted", in: tv))
	}

	@Test @MainActor
	func codeFenceColorsFenceLinesNotCode() {
		let tv = highlighted("```swift\nlet x = 1\n```\n")
		#expect(isColored("```swift", in: tv))
		#expect(isColored("swift", in: tv))
		#expect(!isColored("let x", in: tv))
		#expect(isColored("```", in: tv, occurrence: 1))
	}

	@Test @MainActor
	func codeFenceContentStillSuppressesMarkdown() {
		// Uncoloring code must not let markdown inside a fence get highlighted.
		let tv = highlighted("```\n**not bold**\n```")
		#expect(!isColored("**", in: tv))
	}

	@Test @MainActor
	func everyMarkerUsesTheFadedMarkerColor() {
		// Markup should recede behind the prose, so all markers share the
		// faded marker color rather than heading/code accent colors.
		let tv = highlighted("## Head\n\n**b** *i* `c` [l](u)\n\n> q\n\n- item\n\n---\n\n```\ncode\n```\n")
		let dimmed = NSColor(MarkdownSyntaxHighlighter.markerColor(for: .default))
		let markers = ["## ", "**", "*i", "`c", "[l", "](", "> ", "- ", "---", "```"]
		for marker in markers {
			let location = (tv.string as NSString).range(of: marker).location
			let color = tv.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: location, effectiveRange: nil) as? NSColor
			#expect(color == dimmed, "\(marker) should be dimmed")
		}
	}

	@Test @MainActor
	func linkTextAndURLAreColored() {
		let tv = highlighted("see [the docs](https://example.com) here")
		#expect(isColored("the docs", in: tv))
		#expect(isColored("https", in: tv))
		#expect(!isColored("here", in: tv))
	}
}
#endif
