#if os(macOS)
import AppKit
import Testing
@testable import MarkDownRange

@Suite struct MarkdownSyntaxHighlighterTests {

	// MARK: - Setup

	@MainActor
	private func textView(_ source: String) -> NSTextView {
		let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
		let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
		tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
		tv.string = source
		scroll.documentView = tv
		return tv
	}

	@MainActor
	private func boldRanges(in tv: NSTextView) -> [NSRange] {
		guard let layoutManager = tv.layoutManager, let textStorage = tv.textStorage else { return [] }
		var ranges: [NSRange] = []
		let full = NSRange(location: 0, length: textStorage.length)
		let boldFont = NSFont.monospacedSystemFont(ofSize: tv.font?.pointSize ?? 13, weight: .bold)
		textStorage.enumerateAttribute(.font, in: full) { value, range, _ in
			if let font = value as? NSFont, font == boldFont { ranges.append(range) }
		}
		_ = layoutManager // silence
		return ranges
	}

	// MARK: - Strict (default)

	@Test @MainActor
	func strict_spacedHeadingIsBolded() {
		let tv = textView("# Heading")
		MarkdownSyntaxHighlighter.highlight(textView: tv, theme: .default, options: MarkdownOptions(headingsRequireSpaceAfterHash: true))
		#expect(!boldRanges(in: tv).isEmpty)
	}

	@Test @MainActor
	func strict_noSpaceHeadingIsNotBolded() {
		// CommonMark-strict: `#Heading` (no space) is just a paragraph.
		let tv = textView("#Heading")
		MarkdownSyntaxHighlighter.highlight(textView: tv, theme: .default, options: MarkdownOptions(headingsRequireSpaceAfterHash: true))
		#expect(boldRanges(in: tv).isEmpty)
	}

	// MARK: - Lenient

	@Test @MainActor
	func lenient_noSpaceHeadingIsBolded() {
		let tv = textView("##Heading")
		MarkdownSyntaxHighlighter.highlight(textView: tv, theme: .default, options: MarkdownOptions(headingsRequireSpaceAfterHash: false))
		let ranges = boldRanges(in: tv)
		#expect(!ranges.isEmpty)
		// Whole-line range should cover the full `##Heading`.
		#expect(ranges.contains { $0.length == ("##Heading" as NSString).length })
	}

	@Test @MainActor
	func lenient_spacedHeadingStillBolded() {
		let tv = textView("## Heading")
		MarkdownSyntaxHighlighter.highlight(textView: tv, theme: .default, options: MarkdownOptions(headingsRequireSpaceAfterHash: false))
		#expect(!boldRanges(in: tv).isEmpty)
	}

	@Test @MainActor
	func lenient_sevenHashesNotBolded() {
		// `#######Foo` is not a valid heading even under lenient mode.
		let tv = textView("#######Foo")
		MarkdownSyntaxHighlighter.highlight(textView: tv, theme: .default, options: MarkdownOptions(headingsRequireSpaceAfterHash: false))
		#expect(boldRanges(in: tv).isEmpty)
	}

	@Test @MainActor
	func lenient_codeFenceHashesNotBolded() {
		// `##Heading` inside a code fence stays code-coloured, not heading-styled.
		let tv = textView("```\n##Inside\n```")
		MarkdownSyntaxHighlighter.highlight(textView: tv, theme: .default, options: MarkdownOptions(headingsRequireSpaceAfterHash: false))
		#expect(boldRanges(in: tv).isEmpty)
	}
}
#endif
