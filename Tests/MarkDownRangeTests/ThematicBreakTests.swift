import Testing
@testable import MarkDownRange

@Suite struct ThematicBreakTests {
	@Test func dashes() {
		let blocks = MarkdownBlockParser.parse("---")
		guard case .thematicBreak = blocks.first else {
			Issue.record("Expected thematicBreak"); return
		}
	}

	@Test func stars() {
		let blocks = MarkdownBlockParser.parse("***")
		guard case .thematicBreak = blocks.first else {
			Issue.record("Expected thematicBreak"); return
		}
	}

	@Test func underscores() {
		let blocks = MarkdownBlockParser.parse("___")
		guard case .thematicBreak = blocks.first else {
			Issue.record("Expected thematicBreak"); return
		}
	}

	@Test func dashesWithSpaces() {
		let blocks = MarkdownBlockParser.parse("- - -")
		guard case .thematicBreak = blocks.first else {
			Issue.record("Expected thematicBreak"); return
		}
	}

	@Test func breakBetweenParagraphs() {
		let blocks = MarkdownBlockParser.parse("Above\n\n---\n\nBelow")
		#expect(blocks.count == 3)
		if case .thematicBreak = blocks[1] {} else { Issue.record("Middle should be thematicBreak") }
	}
}
