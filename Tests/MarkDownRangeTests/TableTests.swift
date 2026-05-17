import Testing
import Foundation
@testable import MarkDownRange

@Suite struct TableTests {
	@Test func simpleTable() {
		let md = """
		| Name | Age |
		|------|-----|
		| Alice | 30 |
		| Bob | 25 |
		"""
		let blocks = MarkdownBlockParser.parse(md)
		guard case .table(let header, let rows, _, _) = blocks.first else {
			Issue.record("Expected table"); return
		}
		#expect(header.count == 2)
		#expect(rows.count == 2)
		#expect(String(header[0].characters) == "Name")
		#expect(String(header[1].characters) == "Age")
	}

	@Test func tableWithFormatting() {
		let md = """
		| Feature | Status |
		|---------|--------|
		| **Bold** | *Done* |
		"""
		let blocks = MarkdownBlockParser.parse(md)
		guard case .table(_, let rows, _, _) = blocks.first else {
			Issue.record("Expected table"); return
		}
		let firstCell = String(rows[0][0].characters)
		#expect(firstCell == "Bold")
	}

	@Test func singleColumnTable() {
		let md = """
		| Item |
		|------|
		| One |
		| Two |
		"""
		let blocks = MarkdownBlockParser.parse(md)
		guard case .table(let header, let rows, _, _) = blocks.first else {
			Issue.record("Expected table"); return
		}
		#expect(header.count == 1)
		#expect(rows.count == 2)
	}

	@Test func tableWithLinks() {
		let md = """
		| Site | URL |
		|------|-----|
		| Google | [link](https://google.com) |
		"""
		let blocks = MarkdownBlockParser.parse(md)
		guard case .table(_, let rows, _, _) = blocks.first else {
			Issue.record("Expected table"); return
		}
		let cell = String(rows[0][1].characters)
		#expect(cell.contains("link"))
	}
}
