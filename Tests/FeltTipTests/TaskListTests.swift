import Testing
@testable import FeltTip

@Suite struct TaskListTests {
	@Test func htmlCheckboxesAreDisabledUnlessInteractive() {
		let md = "- [ ] task"
		let staticHTML = MarkdownHTMLRenderer.renderDocument(markdown: md, interactiveCheckboxes: false)
		#expect(staticHTML.contains("disabled"))
		#expect(!staticHTML.contains("data-cb"))

		let interactiveHTML = MarkdownHTMLRenderer.renderDocument(markdown: md, interactiveCheckboxes: true)
		#expect(interactiveHTML.contains("data-cb"))
		#expect(!interactiveHTML.contains("disabled"))
	}

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

	@MainActor
	@Test func nestedParentTaskKeepsCheckboxBesideItsText() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "- [ ] Parent task\n  - [x] Child task\n")
		let alignment = try await harness.evaluate("""
			(() => {
			  const item = document.querySelector('li')
			  const checkbox = item?.querySelector(':scope > input[type="checkbox"], :scope > p > input[type="checkbox"]')
			  const paragraph = item?.querySelector(':scope > p')
			  if (!checkbox || !paragraph) return 'missing'
			  const box = checkbox.getBoundingClientRect()
			  const text = paragraph.getBoundingClientRect()
			  return Math.abs((box.top + box.height / 2) - (text.top + text.height / 2)) < 4
			    ? 'aligned' : 'split'
			})()
			""")
		#expect(alignment == "aligned")
	}
}
