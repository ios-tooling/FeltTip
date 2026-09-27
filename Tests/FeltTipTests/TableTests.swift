import Testing
import Foundation
@testable import FeltTip

@Suite struct TableTests {
	@Test func linkedImageInsideTableHeader() {
		// Pattern from the Stanford CS-229 README — header cells contain
		// `<a href><img/></a>` which should surface as TableCell.image, not
		// the raw HTML text.
		let md = """
		|<a href="https://example.com/a"><img src="https://cdn.example.com/a.png" alt="A" width="220px"/></a>|<a href="https://example.com/b"><img src="https://cdn.example.com/b.png" alt="B" width="220px"/></a>|
		|:--:|:--:|
		|Left|Right|
		"""
		let blocks = MarkdownBlockParser.parse(md)
		guard case .table(let header, _, _, _) = blocks.first else {
			Issue.record("Expected table, got \(blocks.first.debugDescription)"); return
		}
		guard case .image(let src, let alt, let link, let w, _) = header.first else {
			Issue.record("Expected .image header cell, got \(header.first.debugDescription)"); return
		}
		#expect(src == "https://cdn.example.com/a.png")
		#expect(alt == "A")
		#expect(link?.absoluteString == "https://example.com/a")
		#expect(w == 220)
	}

	@Test func tildeInImageURLDoesNotMangleHTMLCell() {
		// Two cells, each containing a URL with `~user` in the path. The
		// subscript preprocessor used to pair the two `~`s across the cells
		// and wrap the entire span (including HTML tag boundaries) in
		// <sub>…</sub>, which left raw HTML in the rendered table.
		let md = """
		|<a href="https://example.com/a"><img src="https://stanford.edu/~shervine/a.png" alt="A" width="220px"/></a>|<a href="https://example.com/b"><img src="https://stanford.edu/~shervine/b.png" alt="B" width="220px"/></a>|
		|:--:|:--:|
		|Left|Right|
		"""
		let blocks = MarkdownBlockParser.parse(md)
		guard case .table(let header, _, _, _) = blocks.first else {
			Issue.record("Expected table"); return
		}
		guard case .image(let src0, _, _, _, _) = header.first,
			  case .image(let src1, _, _, _, _) = header.dropFirst().first else {
			Issue.record("Expected two .image cells"); return
		}
		#expect(src0 == "https://stanford.edu/~shervine/a.png")
		#expect(src1 == "https://stanford.edu/~shervine/b.png")
	}

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
