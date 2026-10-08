//
//  MarkdownItParityTests.swift
//  FeltTipTests
//
//  Mirrors the feature list advertised by https://github.com/markdown-it/markdown-it,
//  so every CommonMark element, GFM extension, plugin, and typographer rule
//  the reference implementation ships with has at least one concrete test
//  here. Where we delegate to swift-markdown for parsing, the assertion just
//  pins the resulting block-tree shape; for our own pre-parse processors the
//  assertion runs against the preprocessor output directly.
//

import Testing
@testable import FeltTip

@Suite struct MarkdownItParityTests {

	// MARK: - CommonMark core

	@Test func commonMark_atxHeadings() {
		let blocks = MarkdownBlockParser.parse("# H1\n## H2\n### H3\n#### H4\n##### H5\n###### H6")
		let levels = blocks.compactMap { if case .heading(let level, _, _) = $0 { return level }; return nil }
		#expect(levels == [1, 2, 3, 4, 5, 6])
	}

	@Test func commonMark_setextHeadings() {
		let blocks = MarkdownBlockParser.parse("Big heading\n===========\n\nSmaller\n-------")
		let levels = blocks.compactMap { if case .heading(let level, _, _) = $0 { return level }; return nil }
		#expect(levels == [1, 2])
	}

	@Test func commonMark_paragraph() {
		let blocks = MarkdownBlockParser.parse("Just a sentence.")
		guard case .paragraph(let content, _, _) = blocks.first else {
			Issue.record("Expected paragraph"); return
		}
		#expect(String(content.characters) == "Just a sentence.")
	}

	@Test func commonMark_emphasisAndStrong() {
		let blocks = MarkdownBlockParser.parse("This is *italic*, **bold**, _italic_, __bold__.")
		guard case .paragraph(let content, _, _) = blocks.first else {
			Issue.record("Expected paragraph"); return
		}
		#expect(String(content.characters) == "This is italic, bold, italic, bold.")
	}

	@Test func commonMark_inlineCode() {
		let blocks = MarkdownBlockParser.parse("Call `foo()` for results.")
		guard case .paragraph(let content, _, _) = blocks.first else {
			Issue.record("Expected paragraph"); return
		}
		#expect(String(content.characters).contains("foo()"))
	}

	@Test func commonMark_fencedCodeBlock() {
		let blocks = MarkdownBlockParser.parse("```swift\nlet x = 1\n```")
		guard case .codeBlock(let code, let language, _, _) = blocks.first else {
			Issue.record("Expected codeBlock"); return
		}
		#expect(language == "swift")
		#expect(code.contains("let x = 1"))
	}

	@Test func commonMark_indentedCodeBlock() {
		let blocks = MarkdownBlockParser.parse("    let x = 1\n    let y = 2")
		guard case .codeBlock(let code, _, _, _) = blocks.first else {
			Issue.record("Expected codeBlock"); return
		}
		#expect(code.contains("let x = 1"))
	}

	@Test func commonMark_unorderedList() {
		let blocks = MarkdownBlockParser.parse("- one\n- two\n- three")
		guard case .unorderedList(let items, _) = blocks.first else {
			Issue.record("Expected unorderedList"); return
		}
		#expect(items.count == 3)
	}

	@Test func commonMark_orderedList() {
		let blocks = MarkdownBlockParser.parse("1. one\n2. two")
		guard case .orderedList(let items, let start, _) = blocks.first else {
			Issue.record("Expected orderedList"); return
		}
		#expect(items.count == 2)
		#expect(start == 1)
	}

	@Test func commonMark_blockquote() {
		let blocks = MarkdownBlockParser.parse("> quoted text")
		guard case .blockquote = blocks.first else {
			Issue.record("Expected blockquote"); return
		}
	}

	@Test func commonMark_thematicBreak() {
		let blocks = MarkdownBlockParser.parse("Paragraph.\n\n---\n\nNext.")
		let hasThematicBreak = blocks.contains { if case .thematicBreak = $0 { return true }; return false }
		#expect(hasThematicBreak)
	}

	@Test func commonMark_inlineLink() {
		let blocks = MarkdownBlockParser.parse("See [Apple](https://apple.com).")
		guard case .paragraph(_, let links, _) = blocks.first else {
			Issue.record("Expected paragraph"); return
		}
		#expect(links.contains { $0.url == "https://apple.com" })
	}

	@Test func commonMark_referenceLink() {
		let blocks = MarkdownBlockParser.parse("See [Apple][apple].\n\n[apple]: https://apple.com")
		guard case .paragraph(_, let links, _) = blocks.first else {
			Issue.record("Expected paragraph"); return
		}
		#expect(links.contains { $0.url == "https://apple.com" })
	}

	@Test func commonMark_image() {
		let blocks = MarkdownBlockParser.parse("![Logo](logo.png)")
		guard case .image(let source, let alt, _, _, _) = blocks.first else {
			Issue.record("Expected image"); return
		}
		#expect(source == "logo.png")
		#expect(alt == "Logo")
	}

	@Test func commonMark_autolink() {
		let blocks = MarkdownBlockParser.parse("<https://example.com>")
		guard case .paragraph(_, let links, _) = blocks.first else {
			Issue.record("Expected paragraph"); return
		}
		#expect(links.contains { $0.url == "https://example.com" })
	}

	@Test func commonMark_htmlBlock() {
		let blocks = MarkdownBlockParser.parse("<div class=\"x\">stuff</div>")
		let hasHTML = blocks.contains { if case .htmlBlock = $0 { return true }; return false }
		#expect(hasHTML)
	}

	@Test func commonMark_inlineHTML_underline() {
		// Inline HTML is recognized — we render <u> via underline.
		let blocks = MarkdownBlockParser.parse("Hello <u>there</u>.")
		guard case .paragraph(let content, _, _) = blocks.first else {
			Issue.record("Expected paragraph"); return
		}
		let plain = String(content.characters)
		#expect(plain.contains("there"))
		#expect(!plain.contains("<u>"))
	}

	@Test func commonMark_escapedCharacter() {
		let blocks = MarkdownBlockParser.parse("\\*literal\\*")
		guard case .paragraph(let content, _, _) = blocks.first else {
			Issue.record("Expected paragraph"); return
		}
		#expect(String(content.characters).contains("*literal*"))
	}

	@Test func commonMark_entityReference() {
		let blocks = MarkdownBlockParser.parse("AT&amp;T")
		guard case .paragraph(let content, _, _) = blocks.first else {
			Issue.record("Expected paragraph"); return
		}
		#expect(String(content.characters).contains("AT&T"))
	}

	// MARK: - GFM extensions

	@Test func gfm_table() {
		let md = "| a | b |\n|---|---|\n| 1 | 2 |"
		let blocks = MarkdownBlockParser.parse(md)
		guard case .table(let header, let rows, _, _) = blocks.first else {
			Issue.record("Expected table"); return
		}
		#expect(header.count == 2)
		#expect(rows.count == 1)
	}

	@Test func gfm_tableRightAlignment() {
		let md = "| a | b |\n|--:|:-:|\n| 1 | 2 |"
		let blocks = MarkdownBlockParser.parse(md)
		guard case .table(_, _, let alignments, _) = blocks.first else {
			Issue.record("Expected table"); return
		}
		#expect(alignments == [.right, .center])
	}

	@Test func gfm_strikethrough() {
		let blocks = MarkdownBlockParser.parse("This is ~~gone~~.")
		guard case .paragraph(let content, _, _) = blocks.first else {
			Issue.record("Expected paragraph"); return
		}
		// Strikethrough should produce a strikethrough style attribute somewhere.
		let hasStrike = content.runs.contains { $0.style.contains(.strikethrough) }
		#expect(hasStrike)
	}

	@Test func gfm_taskList() {
		let blocks = MarkdownBlockParser.parse("- [ ] todo\n- [x] done")
		guard case .unorderedList(let items, _) = blocks.first else {
			Issue.record("Expected unorderedList"); return
		}
		let states = items.compactMap(\.checkbox)
		#expect(states == [.unchecked, .checked])
	}

	@Test func gfm_autolinkBareURL() {
		let blocks = MarkdownBlockParser.parse("Visit https://example.com today.")
		guard case .paragraph(_, let links, _) = blocks.first else {
			Issue.record("Expected paragraph"); return
		}
		#expect(links.contains { $0.url == "https://example.com" })
	}

	// MARK: - markdown-it plugins

	@Test func plugin_subscript_unicode() {
		#expect(SuperSubProcessor.process("H~2~O") == "H₂O")
	}

	@Test func plugin_subscript_htmlFallback() {
		#expect(SuperSubProcessor.process("~Hello~") == "<sub>Hello</sub>")
	}

	@Test func plugin_superscript_unicode() {
		#expect(SuperSubProcessor.process("x^2^") == "x²")
	}

	@Test func plugin_superscript_htmlFallback() {
		#expect(SuperSubProcessor.process("^Big^") == "<sup>Big</sup>")
	}

	@Test func plugin_footnote_referenceLinksToBody() {
		let processed = MarkdownPreprocessor.process("See[^a].\n\n[^a]: A note.")
		// Reference becomes a clickable footnote:// link, body becomes an
		// anchor + back-link.
		#expect(processed.contains("footnote://a"))
		#expect(processed.contains("footnote-anchor://a"))
		#expect(processed.contains("footnote-back://a"))
		#expect(processed.contains("A note."))
	}

	@Test func plugin_definitionList() {
		let blocks = MarkdownBlockParser.parse("Term\n: Definition here")
		guard case .definitionList(let items, _) = blocks.first else {
			Issue.record("Expected definitionList, got \(blocks)"); return
		}
		#expect(items.first?.term == "Term")
		#expect(items.first?.definitions.first == "Definition here")
	}

	@Test func plugin_abbreviation() {
		let input = "*[HTML]: HyperText Markup Language\n\nThe HTML tag."
		let processed = MarkdownPreprocessor.common(after: input)
		#expect(!processed.contains("*[HTML]:"))
		#expect(processed.contains("<abbr title=\"HyperText Markup Language\">HTML</abbr>"))
	}

	@Test func plugin_emoji() {
		#expect(EmojiShortcodes.process(":smile:") == "😄")
		#expect(EmojiShortcodes.process(":yum:") == "😋")
	}

	@Test func plugin_customContainer() {
		let input = """
		::: warning
		Heads up.
		:::
		"""
		let blocks = MarkdownBlockParser.parse(input)
		guard case .alert(let type, _, _) = blocks.first else {
			Issue.record("Expected alert, got \(blocks)"); return
		}
		#expect(type == .warning)
	}

	@Test func plugin_insert() {
		#expect(InsertedTextProcessor.process("This is ++inserted++.") == "This is <u>inserted</u>.")
	}

	@Test func plugin_mark() {
		// HighlightSyntax converts ==text== to <mark>; the inline builder
		// picks up <mark> via its existing handler.
		#expect(HighlightSyntax.process("This is ==highlighted==.") == "This is <mark>highlighted</mark>.")
	}

	// MARK: - Typographer rules

	@Test func typographer_copyright() {
		#expect(SmartTypography.process("(c) Acme") == "© Acme")
		#expect(SmartTypography.process("(C) Acme") == "© Acme")
	}

	@Test func typographer_registered() {
		#expect(SmartTypography.process("(r) Acme") == "® Acme")
		#expect(SmartTypography.process("(R) Acme") == "® Acme")
	}

	@Test func typographer_trademark() {
		#expect(SmartTypography.process("Foo(tm)") == "Foo™")
		#expect(SmartTypography.process("Foo(TM)") == "Foo™")
	}

	@Test func typographer_phonogram() {
		#expect(SmartTypography.process("(p) 2026") == "℗ 2026")
	}

	@Test func typographer_plusMinus() {
		#expect(SmartTypography.process("10+-2") == "10±2")
	}

	@Test func typographer_ellipsis() {
		#expect(SmartTypography.process("wait...") == "wait…")
	}

	@Test func typographer_enDash() {
		#expect(SmartTypography.process("1990--2000") == "1990–2000")
	}

	@Test func typographer_emDash() {
		#expect(SmartTypography.process("yes---really") == "yes—really")
	}

	@Test func typographer_smartQuotes_double() {
		#expect(SmartQuotes.process("She said \"hi\".") == "She said “hi”.")
	}

	@Test func typographer_smartQuotes_single() {
		#expect(SmartQuotes.process("She said 'hi'.") == "She said ‘hi’.")
	}

	@Test func typographer_smartQuotes_apostrophe() {
		// `don't` keeps the closing single quote form.
		#expect(SmartQuotes.process("don't").contains("’"))
	}
}
