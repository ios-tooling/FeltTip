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

	// MARK: - Incremental highlighting

	/// Returns true if the character at `offset` has the bold heading font.
	/// More robust than range-equality checks, which break when NSTextStorage
	/// attribute inheritance merges runs at edit boundaries.
	@MainActor
	private func isBold(at offset: Int, in tv: NSTextView) -> Bool {
		guard let textStorage = tv.textStorage, offset < textStorage.length else { return false }
		let boldFont = NSFont.monospacedSystemFont(ofSize: tv.font?.pointSize ?? 13, weight: .bold)
		let font = textStorage.attribute(.font, at: offset, effectiveRange: nil) as? NSFont
		return font == boldFont
	}

	@Test @MainActor
	func incremental_paragraphEdit_stylesEditedParagraph() {
		// Incremental highlight, scoped to one paragraph, must still bold
		// the heading marker on that paragraph's first line.
		let source = "# First heading\n\n### Middle heading\n\n## Third paragraph"
		let tv = textView(source)
		let editedRange = (source as NSString).range(of: "### Middle heading")
		MarkdownSyntaxHighlighter.highlight(textView: tv, theme: .default, editedRange: editedRange)
		#expect(isBold(at: editedRange.location, in: tv), "Edited heading paragraph should be bolded")
	}

	@Test @MainActor
	func incremental_editInsidePlainParagraph_doesNotTouchDistantParagraphs() {
		// First full-highlight the document. Then call incremental highlight
		// over the middle (plain) paragraph. Top and bottom headings must
		// retain their bold styling — only the middle scope should be
		// re-processed.
		let source = "# Top heading\n\nthis is a long paragraph in the middle\n\n# Bottom heading"
		let tv = textView(source)
		MarkdownSyntaxHighlighter.highlight(textView: tv, theme: .default)
		let top = (source as NSString).range(of: "# Top heading")
		let bottom = (source as NSString).range(of: "# Bottom heading")
		#expect(isBold(at: top.location, in: tv))
		#expect(isBold(at: bottom.location, in: tv))

		let middle = (source as NSString).range(of: "this is a long paragraph in the middle")
		MarkdownSyntaxHighlighter.highlight(textView: tv, theme: .default, editedRange: middle)

		#expect(isBold(at: top.location, in: tv), "Top heading should still be bold after incremental edit elsewhere")
		#expect(isBold(at: bottom.location, in: tv), "Bottom heading should still be bold after incremental edit elsewhere")
		#expect(!isBold(at: middle.location, in: tv), "Middle paragraph is plain prose — should not be bold")
	}

	@Test @MainActor
	func incremental_editTouchingFence_fallsBackToFullDocument() {
		// A fence opener inside the edited probe window means the meaning of
		// distant text could be flipping. The scope decision must be
		// conservative and re-process the whole document, leaving the
		// fenced heading-looking line plain and the outside headings bold.
		let source = "# Heading above\n\n```\n# fenced not a heading\n```\n\n# Heading below"
		let tv = textView(source)
		let fenced = (source as NSString).range(of: "# fenced not a heading")
		MarkdownSyntaxHighlighter.highlight(textView: tv, theme: .default, editedRange: fenced)

		let above = (source as NSString).range(of: "# Heading above")
		let below = (source as NSString).range(of: "# Heading below")
		#expect(isBold(at: above.location, in: tv), "Heading above the fence should be styled even though edit was inside fence")
		#expect(!isBold(at: fenced.location, in: tv), "Line inside the code fence is not a heading")
		#expect(isBold(at: below.location, in: tv), "Heading below the fence should be styled")
	}

	@Test @MainActor
	func incremental_emptyDocument_doesNotCrash() {
		// Regression guard: an editedRange that arrives after the document
		// has been emptied should be silently ignored.
		let tv = textView("")
		MarkdownSyntaxHighlighter.highlight(textView: tv, theme: .default, editedRange: NSRange(location: 0, length: 0))
		#expect(boldRanges(in: tv).isEmpty)
	}

	@Test @MainActor
	func incremental_outOfBoundsRange_isClampedNotCrashed() {
		// If the textStorage shrinks between an edit being captured and the
		// debounced highlight firing, the editedRange may now point past the
		// end of the string. The scope-selection code must clamp safely.
		let tv = textView("# Short doc")
		let stale = NSRange(location: 999, length: 50)
		MarkdownSyntaxHighlighter.highlight(textView: tv, theme: .default, editedRange: stale)
		// We don't assert on styling here — only that no crash occurred.
	}
}
#endif
