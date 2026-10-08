import Testing
@testable import FeltTip

@Suite struct KramdownAttributeListTests {
	@Test func standaloneBlockAttributesDoNotRenderAsProse() {
		let markdown = """
		## Getting started
		{: .-three-column}

		Intro text.
		"""
		let html = MarkdownHTMLRenderer.renderBlocks(MarkdownBlockParser.parse(markdown))

		#expect(html.contains("Getting started"))
		#expect(html.contains("Intro text."))
		#expect(!html.contains("three-column"))
		#expect(!html.contains("{:"))
	}

	@Test func multipleClassesAndAnIDAreIgnored() {
		let html = MarkdownHTMLRenderer.renderBlocks(MarkdownBlockParser.parse(
			"Heading\n{: #intro .wide .-shortcuts}\n\nBody"))

		#expect(!html.contains("shortcuts"))
		#expect(!html.contains("#intro"))
	}

	@Test func proseAndCodeThatLookSimilarRemainVisible() {
		let markdown = """
		Keep {: .example} inline.

		```
		{: .literal-code}
		```
		"""
		let html = MarkdownHTMLRenderer.renderBlocks(MarkdownBlockParser.parse(markdown))

		#expect(html.contains("{: .example}"))
		#expect(html.contains("{: .literal-code}"))
	}

	@Test func removingAnAttributeListPreservesEditableBodyOffsets() throws {
		let markdown = "## Heading\n{: .-three-column}\n\nBody text."
		let blocks = MarkdownBlockParser.parse(markdown, trackSourceOffsets: true)
		let paragraph = blocks.compactMap { block -> InlineContent? in
			if case .paragraph(let content, _, _) = block { return content }
			return nil
		}.first
		let expected = (markdown as NSString).range(of: "Body text.").location

		#expect(try #require(paragraph).runs.first?.markdownSourceOffset == expected)
	}
}
