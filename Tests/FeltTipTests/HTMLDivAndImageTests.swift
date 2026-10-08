import Testing
@testable import FeltTip

@Suite struct HTMLDivAndImageTests {
	@Test func divWithCenteredImageEmitsImage() {
		let md = """
		<div align="center">
			<img src="logo.png" alt="Logo" width="200" height="100">
		</div>
		"""
		let blocks = MarkdownBlockParser.parse(md)
		#expect(!blocks.isEmpty)
		// Either an aligned image or a plain image — both acceptable.
		var found = false
		for block in blocks {
			if case .image(let src, let alt, let w, let h, _) = block {
				#expect(src == "logo.png")
				#expect(alt == "Logo")
				#expect(w == 200)
				#expect(h == 100)
				found = true
			}
			if case .aligned(_, let inner, _) = block,
			   case .image(let src, _, _, _, _) = inner {
				#expect(src == "logo.png")
				found = true
			}
		}
		#expect(found, "Expected an image block somewhere in the output")
	}

	@Test func divWithMultipleImagesEmitsMultipleBlocks() {
		let md = """
		<div>
			<img src="a.png" alt="A">
			<img src="b.png" alt="B">
			<img src="c.png" alt="C">
		</div>
		"""
		let blocks = MarkdownBlockParser.parse(md)
		// Consecutive `<img>` siblings may be emitted either as separate `.image`
		// blocks or grouped into a single `.imageRow` (the current side-by-side
		// rendering path). Both forms are spec-equivalent for this test: what
		// matters is that all three sources survive in order.
		var imageSrcs: [String] = []
		for block in blocks {
			let inner: MarkdownBlock = {
				if case .aligned(_, let b, _) = block { return b }
				return block
			}()
			switch inner {
			case .image(let src, _, _, _, _):
				imageSrcs.append(src)
			case .imageRow(let images, _):
				imageSrcs.append(contentsOf: images.map(\.source))
			default:
				break
			}
		}
		#expect(imageSrcs == ["a.png", "b.png", "c.png"])
	}

	@Test func anchorWrappingDivAndImagePreservesLink() {
		let md = """
		<a href="https://example.com">
			<div>
				<img src="thumb.png" alt="Thumb" width="120">
			</div>
		</a>
		"""
		let blocks = MarkdownBlockParser.parse(md)
		var foundLink = false
		for block in blocks {
			if case .imageRow(let images, _) = block, let img = images.first {
				#expect(img.source == "thumb.png")
				#expect(img.link?.absoluteString == "https://example.com")
				foundLink = true
			}
			if case .aligned(_, let inner, _) = block,
			   case .imageRow(let images, _) = inner, let img = images.first {
				#expect(img.link?.absoluteString == "https://example.com")
				foundLink = true
			}
		}
		#expect(foundLink, "Expected an imageRow with a link preserved through the <div>")
	}

	@Test func mixedImageAndTextEmitsBoth() {
		let md = """
		<p>
			<img src="banner.png" alt="Banner">
			Some descriptive text here.
		</p>
		"""
		let blocks = MarkdownBlockParser.parse(md)
		var hasImage = false
		var hasText = false
		for block in blocks {
			let inner: MarkdownBlock = {
				if case .aligned(_, let b, _) = block { return b }
				return block
			}()
			if case .image = inner { hasImage = true }
			if case .paragraph(let content, _, _) = inner,
			   String(content.characters).contains("descriptive") { hasText = true }
		}
		#expect(hasImage)
		#expect(hasText)
	}

	@Test func nbspInParagraphDecodes() {
		let md = "<p>foo&nbsp;bar&nbsp;baz</p>"
		let blocks = MarkdownBlockParser.parse(md)
		guard case .paragraph(let content, _, _) = blocks.first else {
			Issue.record("Expected paragraph, got \(blocks.first.debugDescription)")
			return
		}
		#expect(String(content.characters).contains("foo\u{00A0}bar"))
	}

	@Test func plainDivWithoutImageOrAnchorStaysAsHTMLBlock() {
		// Sanity: don't regress the existing fall-through behaviour.
		let md = "<div class=\"note\">Just text</div>"
		let blocks = MarkdownBlockParser.parse(md)
		guard case .htmlBlock = blocks.first else {
			Issue.record("Expected htmlBlock, got \(blocks.first.debugDescription)")
			return
		}
	}

	@Test func centeredParagraphWithItalic_preservesAlignmentAndTrait() {
		// User-reported regression: a centered paragraph wrapping <i> lost both
		// the alignment and the italic. The block parser should produce an
		// `.aligned(.center, .paragraph)` whose content carries the italic
		// trait so the native renderer can re-apply it.
		let md = #"<p align="center">"<i>Knowledge is powerful, be careful how you use it!</i>"</p>"#
		let blocks = MarkdownBlockParser.parse(md)
		guard case .aligned(.center, let inner, _) = blocks.first,
			  case .paragraph(let content, _, _) = inner else {
			Issue.record("Expected .aligned(.center, .paragraph), got \(blocks.first.debugDescription)")
			return
		}
		#expect(String(content.characters).contains("Knowledge is powerful"))
		let hasItalic = content.runs.contains { run in
			run.inlineFontTraits.contains(.italic) &&
				run.text.contains("Knowledge")
		}
		#expect(hasItalic, "Italic trait should be preserved on the inner text run")
	}

	@Test func centeredParagraphWithBold_preservesAlignmentAndTrait() {
		let md = #"<p align="center"><b>Heads up</b></p>"#
		let blocks = MarkdownBlockParser.parse(md)
		guard case .aligned(.center, let inner, _) = blocks.first,
			  case .paragraph(let content, _, _) = inner else {
			Issue.record("Expected .aligned(.center, .paragraph), got \(blocks.first.debugDescription)")
			return
		}
		let hasBold = content.runs.contains { run in
			run.inlineFontTraits.contains(.bold) &&
				run.text.contains("Heads up")
		}
		#expect(hasBold, "Bold trait should be preserved on the inner text run")
	}

	@Test func centeredParagraphWithUnderlineAndStrike_preservesAttributes() {
		let md = #"<p align="center"><u>under</u> and <s>strike</s></p>"#
		let blocks = MarkdownBlockParser.parse(md)
		guard case .aligned(.center, let inner, _) = blocks.first,
			  case .paragraph(let content, _, _) = inner else {
			Issue.record("Expected .aligned(.center, .paragraph), got \(blocks.first.debugDescription)")
			return
		}
		let hasUnderline = content.runs.contains { $0.text.contains("under") && $0.style.contains(.underline) }
		let hasStrike = content.runs.contains { $0.text.contains("strike") && $0.style.contains(.strikethrough) }
		#expect(hasUnderline, "<u> should set underlineStyle")
		#expect(hasStrike, "<s> should set strikethroughStyle")
	}

	@Test func centeredParagraphWithItalicAndLink_preservesBoth() {
		// Anchor-bearing paragraphs go through buildParagraph rather than the
		// no-anchor text path. The widened formatter should keep italic on
		// the leading text AND emit the link unchanged.
		let md = #"<p align="center"><i>See</i> the <a href="https://apple.com">docs</a>.</p>"#
		let blocks = MarkdownBlockParser.parse(md)
		guard case .aligned(.center, let inner, _) = blocks.first,
			  case .paragraph(let content, let links, _) = inner else {
			Issue.record("Expected .aligned(.center, .paragraph), got \(blocks.first.debugDescription)")
			return
		}
		let hasItalicOnSee = content.runs.contains { run in
			run.inlineFontTraits.contains(.italic) &&
				run.text.contains("See")
		}
		#expect(hasItalicOnSee, "Italic outside the anchor should survive buildParagraph")
		#expect(links.contains { $0.url == "https://apple.com" }, "Link URL should reach LinkInfo")
		let hasLinkAttr = content.runs.contains { run in
			run.link?.absoluteString == "https://apple.com" &&
				run.text.contains("docs")
		}
		#expect(hasLinkAttr, "Link attribute should land on the anchor label")
	}

	@Test func paragraphWithItalicInsideLink_preservesLabelItalic() {
		// Italic INSIDE the <a> label used to be stripped because the label was
		// passed through stripTags. The widened formatter keeps it.
		let md = #"<p>Read <a href="https://example.com"><i>more</i></a> here.</p>"#
		let blocks = MarkdownBlockParser.parse(md)
		guard case .paragraph(let content, _, _) = blocks.first else {
			Issue.record("Expected .paragraph, got \(blocks.first.debugDescription)")
			return
		}
		let italicLinkRun = content.runs.first { run in
			run.inlineFontTraits.contains(.italic) &&
				run.link?.absoluteString == "https://example.com" &&
				run.text.contains("more")
		}
		#expect(italicLinkRun != nil, "Anchor inner italic should be carried on the link run")
	}

	@Test func rightAlignedParagraph_emitsTrailingAlignment() {
		let md = #"<p align="right">aligned right</p>"#
		let blocks = MarkdownBlockParser.parse(md)
		guard case .aligned(.trailing, _, _) = blocks.first else {
			Issue.record("Expected .aligned(.trailing, ...), got \(blocks.first.debugDescription)")
			return
		}
	}

	@Test func brBetweenImages_keepsThemInOneRow() {
		// `<br>` between badges in a `<p align="center">` block used to split
		// the row into two `.imageRow` blocks, which put each row in its own
		// VStack child with a fixed parent spacing. The flow layout in
		// ImageRowView now handles wrapping itself, so all images stay in a
		// single `.imageRow` and the inter-row gap is controlled by
		// `FlowLayout.verticalSpacing`.
		let md = """
		<p align="center">
		  <img src="a.png">
		  <img src="b.png">
		  <br>
		  <img src="c.png">
		  <img src="d.png">
		</p>
		"""
		let blocks = MarkdownBlockParser.parse(md)
		let imageRows: [[String]] = blocks.compactMap { block -> [String]? in
			let inner: MarkdownBlock = {
				if case .aligned(_, let b, _) = block { return b }
				return block
			}()
			if case .imageRow(let images, _) = inner {
				return images.map(\.source)
			}
			return nil
		}
		#expect(imageRows == [["a.png", "b.png", "c.png", "d.png"]])
	}
}
