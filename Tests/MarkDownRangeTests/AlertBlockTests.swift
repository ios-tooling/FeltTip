import Testing
@testable import MarkDownRange

@Suite struct AlertBlockTests {
	@Test func noteAlert() {
		let md = "> [!NOTE]\n> This is a note."
		let blocks = MarkdownBlockParser.parse(md)
		guard case .alert(let type, let children, _) = blocks.first else {
			Issue.record("Expected alert, got \(blocks.first.debugDescription)"); return
		}
		#expect(type == .note)
		#expect(!children.isEmpty)
	}

	@Test func warningAlert() {
		let md = "> [!WARNING]\n> Be careful!"
		let blocks = MarkdownBlockParser.parse(md)
		guard case .alert(let type, _, _) = blocks.first else {
			Issue.record("Expected alert"); return
		}
		#expect(type == .warning)
	}

	@Test func tipAlert() {
		let md = "> [!TIP]\n> Here is a tip."
		let blocks = MarkdownBlockParser.parse(md)
		guard case .alert(let type, _, _) = blocks.first else {
			Issue.record("Expected alert"); return
		}
		#expect(type == .tip)
	}

	@Test func importantAlert() {
		let md = "> [!IMPORTANT]\n> Do not skip this."
		let blocks = MarkdownBlockParser.parse(md)
		guard case .alert(let type, _, _) = blocks.first else {
			Issue.record("Expected alert"); return
		}
		#expect(type == .important)
	}

	@Test func cautionAlert() {
		let md = "> [!CAUTION]\n> This is dangerous."
		let blocks = MarkdownBlockParser.parse(md)
		guard case .alert(let type, _, _) = blocks.first else {
			Issue.record("Expected alert"); return
		}
		#expect(type == .caution)
	}

	@Test func caseInsensitive() {
		let md = "> [!note]\n> Lowercase works too."
		let blocks = MarkdownBlockParser.parse(md)
		guard case .alert(let type, _, _) = blocks.first else {
			Issue.record("Expected alert"); return
		}
		#expect(type == .note)
	}

	@Test func regularBlockquoteUnchanged() {
		let md = "> Just a regular quote."
		let blocks = MarkdownBlockParser.parse(md)
		guard case .blockquote = blocks.first else {
			Issue.record("Expected regular blockquote, got \(blocks.first.debugDescription)"); return
		}
	}

	@Test func allAlertTypes() {
		for type in AlertType.allCases {
			#expect(!type.label.isEmpty)
			#expect(!type.icon.isEmpty)
		}
	}
}
