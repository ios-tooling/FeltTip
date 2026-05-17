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

	@Test func htmlParagraphConvertedToNativeBlock() {
		let md = "<p>Hello <strong>world</strong></p>"
		let blocks = MarkdownBlockParser.parse(md)
		guard case .paragraph(let content, _, _) = blocks.first else {
			Issue.record("Expected paragraph, got \(blocks.first.debugDescription)"); return
		}
		#expect(String(content.characters).contains("Hello"))
	}

	@Test func htmlTableConvertedToTableBlock() {
		let md = """
		<table>
		  <tr>
		    <th>Name</th><th>Role</th>
		  </tr>
		  <tr>
		    <td>Alice</td><td>Engineer</td>
		  </tr>
		  <tr>
		    <td>Bob</td><td>Designer</td>
		  </tr>
		</table>
		"""
		let blocks = MarkdownBlockParser.parse(md)
		guard case .table(let header, let rows, _, _) = blocks.first else {
			Issue.record("Expected table, got \(blocks.first.debugDescription)"); return
		}
		#expect(header.count == 2)
		#expect(String(header[0].characters) == "Name")
		#expect(rows.count == 2)
		#expect(String(rows[0][0].characters) == "Alice")
		#expect(String(rows[1][1].characters) == "Designer")
	}

	@Test func htmlTableWithLinkedImages() {
		let md = """
		<table>
		  <tr>
		    <td><a href="https://example.com"><img src="logo.png" alt="Example"></a></td>
		    <td><a href="https://other.com"><img src="other.png" alt="Other"></a></td>
		  </tr>
		</table>
		"""
		let blocks = MarkdownBlockParser.parse(md)
		guard case .table(_, let rows, _, _) = blocks.first else {
			Issue.record("Expected table"); return
		}
		#expect(rows.count == 1)
		#expect(rows[0].count == 2)
		let cell = String(rows[0][0].characters)
		#expect(cell == "Example")
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
