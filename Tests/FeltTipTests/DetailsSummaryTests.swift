import Testing
@testable import FeltTip

@Suite struct DetailsSummaryTests {
	@Test func parsesDetailsSummary() {
		let md = """
		<details>
		<summary>Click to expand</summary>

		This is the hidden content.

		</details>
		"""
		let blocks = MarkdownBlockParser.parse(md)
		guard case .details(let summary, _, let children, _) = blocks.first else {
			Issue.record("Expected details block, got \(blocks.map { $0.id })"); return
		}
		#expect(summary == "Click to expand")
		#expect(!children.isEmpty)
	}

	@Test func detailsWithMarkdownContent() {
		let md = """
		<details>
		<summary>More info</summary>

		- Item 1
		- Item 2

		**Bold text** here.

		</details>
		"""
		let blocks = MarkdownBlockParser.parse(md)
		guard case .details(_, _, let children, _) = blocks.first else {
			Issue.record("Expected details block"); return
		}
		#expect(children.count >= 1, "Should have parsed markdown children")
	}

	@Test func detailsWithoutSummary() {
		let md = """
		<details>

		Content without summary.

		</details>
		"""
		let blocks = MarkdownBlockParser.parse(md)
		guard case .details(let summary, _, _, _) = blocks.first else {
			Issue.record("Expected details block"); return
		}
		#expect(summary == "Details", "Default summary should be 'Details'")
	}

	@Test func openDetailsRendersExpanded() {
		let markdown = """
		<details open>
		<summary>Already expanded</summary>

		Visible content.

		</details>
		"""

		let html = MarkdownHTMLRenderer.renderBodyFragment(markdown: markdown)
		#expect(html.contains("<details open>"))
	}

	@Test func regularHTMLNotDetails() {
		let md = "<div>Not a details block</div>"
		let blocks = MarkdownBlockParser.parse(md)
		guard case .htmlBlock = blocks.first else {
			Issue.record("Expected htmlBlock, not details"); return
		}
	}
}
