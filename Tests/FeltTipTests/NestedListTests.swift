import Testing
@testable import FeltTip

@Suite struct NestedListTests {
	@Test func nestedUnorderedList() {
		let md = """
		- Item 1
		  - Sub-item A
		  - Sub-item B
		- Item 2
		"""
		let blocks = MarkdownBlockParser.parse(md)
		guard case .unorderedList(let items, _) = blocks.first else {
			Issue.record("Expected unorderedList"); return
		}
		#expect(items.count == 2)
		// First item should contain a nested list
		let firstItemBlocks = items[0].blocks
		let hasNestedList = firstItemBlocks.contains { block in
			if case .unorderedList = block { return true }
			return false
		}
		#expect(hasNestedList, "First item should contain a nested unordered list")
	}

	@Test func nestedOrderedList() {
		let md = """
		1. First
		   1. Sub-first
		   2. Sub-second
		2. Second
		"""
		let blocks = MarkdownBlockParser.parse(md)
		guard case .orderedList(let items, _, _) = blocks.first else {
			Issue.record("Expected orderedList"); return
		}
		#expect(items.count == 2)
		let hasNestedList = items[0].blocks.contains { block in
			if case .orderedList = block { return true }
			return false
		}
		#expect(hasNestedList, "First item should contain a nested ordered list")
	}

	@Test func threeDeepNesting() {
		let md = """
		- Level 1
		  - Level 2
		    - Level 3
		"""
		let blocks = MarkdownBlockParser.parse(md)
		guard case .unorderedList(let l1Items, _) = blocks.first else {
			Issue.record("Expected unorderedList"); return
		}
		// Level 1 → Level 2
		guard case .unorderedList(let l2Items, _) = l1Items[0].blocks.last else {
			Issue.record("Expected nested list in level 1"); return
		}
		// Level 2 → Level 3
		guard case .unorderedList(_, _) = l2Items[0].blocks.last else {
			Issue.record("Expected nested list in level 2"); return
		}
	}

	@Test func mixedListNesting() {
		let md = """
		1. Ordered item
		   - Unordered sub
		   - Another unordered sub
		"""
		let blocks = MarkdownBlockParser.parse(md)
		guard case .orderedList(let items, _, _) = blocks.first else {
			Issue.record("Expected orderedList"); return
		}
		let hasUnorderedNested = items[0].blocks.contains { block in
			if case .unorderedList = block { return true }
			return false
		}
		#expect(hasUnorderedNested, "Ordered list should contain nested unordered list")
	}
}
