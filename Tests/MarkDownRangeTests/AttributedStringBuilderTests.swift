#if os(macOS)
import Testing
import Foundation
import AppKit
@testable import MarkDownRange

@Suite @MainActor struct AttributedStringBuilderTests {
	private func build(_ md: String) async -> NSAttributedString {
		let blocks = MarkdownBlockParser.parse(md)
		return await MarkdownAttributedStringBuilder.build(blocks: blocks, theme: .default, fontSize: 16)
	}

	@Test func headingProducesText() async {
		let ns = await build("# Hello")
		#expect(ns.string.contains("Hello"))
	}

	@Test func headingFontIsLargerThanBody() async {
		let ns = await build("# Big\n\nbody")
		let headingFont = ns.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
		// "Big\n" is 4 chars; body starts after that.
		let bodyFont = ns.attribute(.font, at: 4, effectiveRange: nil) as? NSFont
		#expect(headingFont != nil && bodyFont != nil)
		#expect((headingFont?.pointSize ?? 0) > (bodyFont?.pointSize ?? 0))
	}

	@Test func paragraphIncludesContent() async {
		let ns = await build("Some plain text.")
		#expect(ns.string.contains("Some plain text."))
	}

	@Test func linkAttributeBridges() async {
		let ns = await build("Visit [Apple](https://apple.com).")
		var found: URL?
		ns.enumerateAttribute(.link, in: NSRange(location: 0, length: ns.length), options: []) { value, _, _ in
			if let url = value as? URL { found = url }
			else if let s = value as? String, let url = URL(string: s) { found = url }
		}
		#expect(found?.absoluteString == "https://apple.com")
	}

	@Test func unorderedListEmitsBullets() async {
		let ns = await build("- one\n- two\n- three")
		#expect(ns.string.contains("• one"))
		#expect(ns.string.contains("• two"))
		#expect(ns.string.contains("• three"))
	}

	@Test func orderedListEmitsNumbers() async {
		let ns = await build("1. first\n2. second")
		#expect(ns.string.contains("1. first"))
		#expect(ns.string.contains("2. second"))
	}

	@Test func codeBlockBecomesAttachment() async {
		// Phase 4 renders code blocks via an NSTextAttachment that hosts
		// CodeBlockView; the syntax highlighting and monospacing live inside
		// the SwiftUI view rather than as text-storage attributes.
		let ns = await build("```\nlet x = 1\n```")
		let attachment = ns.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
		#expect(attachment is SwiftUIAttachment)
	}

	@Test func thematicBreakRendersAsLine() async {
		let ns = await build("before\n\n---\n\nafter")
		#expect(ns.string.contains("─"))
	}

	@Test func emptyDocumentProducesEmptyString() async {
		let ns = await build("")
		#expect(ns.length == 0)
	}

	@Test func inlineBoldProducesBoldFont() async {
		let ns = await build("This is **bold** here.")
		let boldRange = (ns.string as NSString).range(of: "bold")
		let font = ns.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont
		#expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
	}

	@Test func inlineItalicProducesItalicFont() async {
		let ns = await build("This is *italic* here.")
		let italicRange = (ns.string as NSString).range(of: "italic")
		let font = ns.attribute(.font, at: italicRange.location, effectiveRange: nil) as? NSFont
		#expect(font?.fontDescriptor.symbolicTraits.contains(.italic) == true)
	}

	@Test func inlineCodeProducesMonospacedFont() async {
		let ns = await build("Use `let x = 1` here.")
		let codeRange = (ns.string as NSString).range(of: "let x = 1")
		let font = ns.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont
		#expect(font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
	}

	@Test func boldInsideHeadingPreservesHeadingSize() async {
		// Inline bold inside a heading should be both bold AND heading-sized,
		// not collapsed to body-bold.
		let ns = await build("# A **bold** heading")
		let plainRange = (ns.string as NSString).range(of: "A ")
		let boldRange = (ns.string as NSString).range(of: "bold")
		let plainFont = ns.attribute(.font, at: plainRange.location, effectiveRange: nil) as? NSFont
		let boldFont = ns.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont
		#expect(plainFont?.pointSize == boldFont?.pointSize)
		#expect(boldFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
	}

	@Test func centeredHTMLParagraph_stampsCenterAlignment() async {
		// The `.aligned(.center, ...)` wrapper produced by HTMLInlineConverter
		// must reach the NSParagraphStyle as `.center` — the native renderer
		// used to drop the alignment on the floor and render the paragraph
		// flush-left.
		let ns = await build(#"<p align="center"><i>Hello there</i></p>"#)
		let range = (ns.string as NSString).range(of: "Hello there")
		#expect(range.location != NSNotFound)
		let style = ns.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
		#expect(style?.alignment == .center)
	}

	@Test func centeredHTMLParagraph_preservesItalicFont() async {
		// Italic inside a centered <p> survives all the way to the rendered
		// NSFont — proves InlineFontTraits emitted by HTMLInlineConverter is
		// honored by the native renderer in the aligned-paragraph code path.
		let ns = await build(#"<p align="center"><i>Hello there</i></p>"#)
		let range = (ns.string as NSString).range(of: "Hello there")
		#expect(range.location != NSNotFound)
		let font = ns.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
		#expect(font?.fontDescriptor.symbolicTraits.contains(.italic) == true)
	}

	@Test func rightAlignedHTMLParagraph_stampsRightAlignment() async {
		let ns = await build(#"<p align="right">flush right</p>"#)
		let range = (ns.string as NSString).range(of: "flush right")
		let style = ns.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
		#expect(style?.alignment == .right)
	}

	@Test func centeredHTMLHeading_stampsCenterAlignment() async {
		// `<h1 align="center">` flows through HTMLHeadingParser → .aligned →
		// appendHeading. Verify the heading paragraph style picks up center.
		let ns = await build(#"<h1 align="center">Title</h1>"#)
		let range = (ns.string as NSString).range(of: "Title")
		let style = ns.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
		#expect(style?.alignment == .center)
	}

	@Test func standaloneHTMLCommentLine_doesNotLeakIntoOutput() async {
		// SmartTypography used to en-dash the `--` inside `<!-- comment -->`,
		// which made CommonMark stop seeing it as an HTML block — the mangled
		// comment text then leaked into the rendered output as a paragraph.
		let ns = await build("""
		<!-- prettier-ignore-start -->

		Visible paragraph.

		<!-- prettier-ignore-end -->
		""")
		#expect(ns.string.contains("Visible paragraph"))
		#expect(!ns.string.contains("prettier-ignore-start"))
		#expect(!ns.string.contains("prettier-ignore-end"))
	}

	@Test func commentOnlyHTMLBlock_doesNotProduceAttachment() async {
		// Empty HTML-comment blocks used to survive into the rendered output
		// as 24pt-tall transparent attachments with paragraph spacing above
		// and below — visible as a conspicuous gap. The parser now drops
		// comment-only HTML blocks before rendering.
		let ns = await build("""
		Before.

		<!-- a -->
		<!-- b -->

		After.
		""")
		var attachments: [NSTextAttachment] = []
		ns.enumerateAttribute(.attachment, in: NSRange(location: 0, length: ns.length)) { value, _, _ in
			if let a = value as? NSTextAttachment { attachments.append(a) }
		}
		#expect(attachments.isEmpty, "Comment-only HTML blocks should not produce attachments")
	}

	@Test func imageAttachment_usesContainerWidth() async {
		// Wide cover images used to render at the static 700pt measurement
		// fallback, overflowing narrower windows. Image-bearing blocks should
		// now report usesContainerWidth=true so the renderer remeasures them
		// to fit the actual text container.
		let ns = await build("![Cover](https://example.com/cover.png)")
		var attachment: SwiftUIAttachment?
		ns.enumerateAttribute(.attachment, in: NSRange(location: 0, length: ns.length)) { value, _, _ in
			if let a = value as? SwiftUIAttachment { attachment = a }
		}
		#expect(attachment?.usesContainerWidth == true, "Single image block should fit container width")
	}

	@Test func linkedImageAttachment_usesContainerWidth() async {
		// `[![alt](src)](href)` collapses into an `.imageRow` with one item;
		// it must also fit the container width or wide cover images overflow.
		let ns = await build("[![Cover](https://example.com/cover.png)](https://example.com)")
		var attachment: SwiftUIAttachment?
		ns.enumerateAttribute(.attachment, in: NSRange(location: 0, length: ns.length)) { value, _, _ in
			if let a = value as? SwiftUIAttachment { attachment = a }
		}
		#expect(attachment?.usesContainerWidth == true, "Linked image (imageRow) should fit container width")
	}

	@Test func plainTextHasNoEmphasisTraits() async {
		let ns = await build("Just plain text.")
		let font = ns.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
		let traits = font?.fontDescriptor.symbolicTraits ?? []
		#expect(!traits.contains(.bold))
		#expect(!traits.contains(.italic))
		#expect(!traits.contains(.monoSpace))
	}

	@Test func onProgress_firesOnceAtCompletion() async {
		// Build invokes onProgress only at the very end with value 1.0.
		// Mid-build yields are off because each one drains queued main-actor
		// work from the per-attachment NSHostingController sizing and so
		// costs ~200ms per yield independent of the host. When the sizing
		// path is replaced (Step 3) we can re-introduce intermediate ticks.
		let md = LargeMarkdownGeneratorMini.generate(sections: 30)
		let blocks = MarkdownBlockParser.parse(md)
		var values: [Double] = []
		_ = await MarkdownAttributedStringBuilder.build(
			blocks: blocks,
			theme: .default,
			fontSize: 16,
			onProgress: { values.append($0) }
		)
		#expect(values == [1.0], "Build should fire onProgress exactly once with 1.0 (got \(values))")
	}

	@Test func largeDocumentDoesNotCrash() async {
		// Sanity check on a realistic doc; correctness already covered above.
		let blocks = MarkdownBlockParser.parse(LargeMarkdownGeneratorMini.generate(sections: 20))
		let ns = await MarkdownAttributedStringBuilder.build(blocks: blocks, theme: .default, fontSize: 16)
		#expect(ns.length > 0)
	}
}

private enum LargeMarkdownGeneratorMini {
	static func generate(sections: Int) -> String {
		var lines: [String] = []
		for i in 1...sections {
			lines.append("# Section \(i)")
			lines.append("")
			lines.append("Paragraph with [a link](https://example.com/\(i)) and *some* emphasis.")
			lines.append("")
			lines.append("- bullet a")
			lines.append("- bullet b")
			lines.append("")
			lines.append("```")
			lines.append("code line \(i)")
			lines.append("```")
			lines.append("")
		}
		return lines.joined(separator: "\n")
	}
}
#endif
