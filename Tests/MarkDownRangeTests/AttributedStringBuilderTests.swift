#if os(macOS)
import Testing
import Foundation
import AppKit
@testable import MarkDownRange

@Suite @MainActor struct AttributedStringBuilderTests {
	private func build(_ md: String) -> NSAttributedString {
		let blocks = MarkdownBlockParser.parse(md)
		return MarkdownAttributedStringBuilder.build(blocks: blocks, theme: .default, fontSize: 16)
	}

	@Test func headingProducesText() {
		let ns = build("# Hello")
		#expect(ns.string.contains("Hello"))
	}

	@Test func headingFontIsLargerThanBody() {
		let ns = build("# Big\n\nbody")
		let headingFont = ns.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
		// "Big\n" is 4 chars; body starts after that.
		let bodyFont = ns.attribute(.font, at: 4, effectiveRange: nil) as? NSFont
		#expect(headingFont != nil && bodyFont != nil)
		#expect((headingFont?.pointSize ?? 0) > (bodyFont?.pointSize ?? 0))
	}

	@Test func paragraphIncludesContent() {
		let ns = build("Some plain text.")
		#expect(ns.string.contains("Some plain text."))
	}

	@Test func linkAttributeBridges() {
		let ns = build("Visit [Apple](https://apple.com).")
		var found: URL?
		ns.enumerateAttribute(.link, in: NSRange(location: 0, length: ns.length), options: []) { value, _, _ in
			if let url = value as? URL { found = url }
			else if let s = value as? String, let url = URL(string: s) { found = url }
		}
		#expect(found?.absoluteString == "https://apple.com")
	}

	@Test func unorderedListEmitsBullets() {
		let ns = build("- one\n- two\n- three")
		#expect(ns.string.contains("• one"))
		#expect(ns.string.contains("• two"))
		#expect(ns.string.contains("• three"))
	}

	@Test func orderedListEmitsNumbers() {
		let ns = build("1. first\n2. second")
		#expect(ns.string.contains("1. first"))
		#expect(ns.string.contains("2. second"))
	}

	@Test func codeBlockBecomesAttachment() {
		// Phase 4 renders code blocks via an NSTextAttachment that hosts
		// CodeBlockView; the syntax highlighting and monospacing live inside
		// the SwiftUI view rather than as text-storage attributes.
		let ns = build("```\nlet x = 1\n```")
		let attachment = ns.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
		#expect(attachment is SwiftUIAttachment)
	}

	@Test func thematicBreakRendersAsLine() {
		let ns = build("before\n\n---\n\nafter")
		#expect(ns.string.contains("─"))
	}

	@Test func emptyDocumentProducesEmptyString() {
		let ns = build("")
		#expect(ns.length == 0)
	}

	@Test func inlineBoldProducesBoldFont() {
		let ns = build("This is **bold** here.")
		let boldRange = (ns.string as NSString).range(of: "bold")
		let font = ns.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont
		#expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
	}

	@Test func inlineItalicProducesItalicFont() {
		let ns = build("This is *italic* here.")
		let italicRange = (ns.string as NSString).range(of: "italic")
		let font = ns.attribute(.font, at: italicRange.location, effectiveRange: nil) as? NSFont
		#expect(font?.fontDescriptor.symbolicTraits.contains(.italic) == true)
	}

	@Test func inlineCodeProducesMonospacedFont() {
		let ns = build("Use `let x = 1` here.")
		let codeRange = (ns.string as NSString).range(of: "let x = 1")
		let font = ns.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont
		#expect(font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
	}

	@Test func boldInsideHeadingPreservesHeadingSize() {
		// Inline bold inside a heading should be both bold AND heading-sized,
		// not collapsed to body-bold.
		let ns = build("# A **bold** heading")
		let plainRange = (ns.string as NSString).range(of: "A ")
		let boldRange = (ns.string as NSString).range(of: "bold")
		let plainFont = ns.attribute(.font, at: plainRange.location, effectiveRange: nil) as? NSFont
		let boldFont = ns.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont
		#expect(plainFont?.pointSize == boldFont?.pointSize)
		#expect(boldFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
	}

	@Test func plainTextHasNoEmphasisTraits() {
		let ns = build("Just plain text.")
		let font = ns.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
		let traits = font?.fontDescriptor.symbolicTraits ?? []
		#expect(!traits.contains(.bold))
		#expect(!traits.contains(.italic))
		#expect(!traits.contains(.monoSpace))
	}

	@Test func largeDocumentDoesNotCrash() {
		// Sanity check on a realistic doc; correctness already covered above.
		let blocks = MarkdownBlockParser.parse(LargeMarkdownGeneratorMini.generate(sections: 20))
		let ns = MarkdownAttributedStringBuilder.build(blocks: blocks, theme: .default, fontSize: 16)
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
