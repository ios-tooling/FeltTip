import Testing
@testable import MarkDownRange

@Suite struct TaskListTests {
	@Test func parsesCheckedItem() {
		let blocks = MarkdownBlockParser.parse("- [x] Done task")
		guard case .unorderedList(let items, _) = blocks.first else {
			Issue.record("Expected unorderedList"); return
		}
		#expect(items.count == 1)
		#expect(items[0].checkbox == .checked)
	}

	@Test func parsesUncheckedItem() {
		let blocks = MarkdownBlockParser.parse("- [ ] Todo task")
		guard case .unorderedList(let items, _) = blocks.first else {
			Issue.record("Expected unorderedList"); return
		}
		#expect(items.count == 1)
		#expect(items[0].checkbox == .unchecked)
	}

	@Test func mixedTaskList() {
		let md = """
		- [x] First done
		- [ ] Second todo
		- [x] Third done
		"""
		let blocks = MarkdownBlockParser.parse(md)
		guard case .unorderedList(let items, _) = blocks.first else {
			Issue.record("Expected unorderedList"); return
		}
		#expect(items.count == 3)
		#expect(items[0].checkbox == .checked)
		#expect(items[1].checkbox == .unchecked)
		#expect(items[2].checkbox == .checked)
	}

	@Test func regularListHasNoCheckbox() {
		let blocks = MarkdownBlockParser.parse("- Regular item")
		guard case .unorderedList(let items, _) = blocks.first else {
			Issue.record("Expected unorderedList"); return
		}
		#expect(items[0].checkbox == nil)
	}

	@Test func orderedListWithCheckbox() {
		let blocks = MarkdownBlockParser.parse("1. [x] Ordered checked")
		guard case .orderedList(let items, _, _) = blocks.first else {
			Issue.record("Expected orderedList"); return
		}
		#expect(items[0].checkbox == .checked)
	}
}
