import Testing
@testable import MarkDownRange

@Suite struct ListTests {
	@Test func unorderedDash() {
		let blocks = MarkdownBlockParser.parse("- One\n- Two\n- Three")
		guard case .unorderedList(let items, _) = blocks.first else {
			Issue.record("Expected unorderedList"); return
		}
		#expect(items.count == 3)
	}

	@Test func unorderedStar() {
		let blocks = MarkdownBlockParser.parse("* One\n* Two")
		guard case .unorderedList(let items, _) = blocks.first else {
			Issue.record("Expected unorderedList"); return
		}
		#expect(items.count == 2)
	}

	@Test func unorderedPlus() {
		let blocks = MarkdownBlockParser.parse("+ One\n+ Two")
		guard case .unorderedList(let items, _) = blocks.first else {
			Issue.record("Expected unorderedList"); return
		}
		#expect(items.count == 2)
	}

	@Test func orderedList() {
		let blocks = MarkdownBlockParser.parse("1. First\n2. Second\n3. Third")
		guard case .orderedList(let items, let start, _) = blocks.first else {
			Issue.record("Expected orderedList"); return
		}
		#expect(items.count == 3)
		#expect(start == 1)
	}

	@Test func orderedListStartingAt5() {
		let blocks = MarkdownBlockParser.parse("5. Fifth\n6. Sixth")
		guard case .orderedList(_, let start, _) = blocks.first else {
			Issue.record("Expected orderedList"); return
		}
		#expect(start == 5)
	}

	@Test func listItemWithMultipleParagraphs() {
		let md = "- First paragraph\n\n  Second paragraph\n\n- Next item"
		let blocks = MarkdownBlockParser.parse(md)
		guard case .unorderedList(let items, _) = blocks.first else {
			Issue.record("Expected unorderedList"); return
		}
		#expect(items[0].blocks.count >= 2, "First item should have multiple block children")
	}

	@Test func listWithInlineFormatting() {
		let blocks = MarkdownBlockParser.parse("- **Bold** item\n- *Italic* item")
		guard case .unorderedList(let items, _) = blocks.first else {
			Issue.record("Expected unorderedList"); return
		}
		#expect(items.count == 2)
	}

	@Test func emptyListItem() {
		let blocks = MarkdownBlockParser.parse("- \n- Item")
		guard case .unorderedList(let items, _) = blocks.first else {
			Issue.record("Expected unorderedList"); return
		}
		#expect(items.count >= 1)
	}
}
