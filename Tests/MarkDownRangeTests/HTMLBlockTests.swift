import Testing
@testable import MarkDownRange

@Suite struct HTMLBlockTests {
	@Test func parsesHTMLBlock() {
		let md = """
		<div class="note">
		This is a note
		</div>
		"""
		let blocks = MarkdownBlockParser.parse(md)
		guard case .htmlBlock(let content, _) = blocks.first else {
			Issue.record("Expected htmlBlock, got \(blocks.first.debugDescription)")
			return
		}
		#expect(content.contains("note"))
	}

	@Test func htmlBlockPreservesContent() {
		let md = "<p>Hello <strong>world</strong></p>"
		let blocks = MarkdownBlockParser.parse(md)
		guard case .htmlBlock(let content, _) = blocks.first else {
			Issue.record("Expected htmlBlock"); return
		}
		#expect(content.contains("Hello"))
		#expect(content.contains("<strong>"))
	}

	@Test func htmlBlockAmongMarkdown() {
		let md = """
		# Title

		<div>HTML content</div>

		Regular paragraph
		"""
		let blocks = MarkdownBlockParser.parse(md)
		#expect(blocks.count >= 3)
		if case .heading = blocks[0] {} else { Issue.record("Expected heading first") }
		if case .htmlBlock = blocks[1] {} else { Issue.record("Expected htmlBlock second") }
		if case .paragraph = blocks[2] {} else { Issue.record("Expected paragraph third") }
	}
}
