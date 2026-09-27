import Testing
@testable import FeltTip

@Suite struct MarkdownOptionsTests {
	@Test func defaultIsLenient() {
		#expect(!MarkdownOptions.default.headingsRequireSpaceAfterHash)
	}

	@Test func strict_treatsNoSpaceAsParagraph() {
		// CommonMark-strict: `##Heading` (no space) is not a heading.
		let options = MarkdownOptions(headingsRequireSpaceAfterHash: true)
		let blocks = MarkdownBlockParser.parse("##Heading", options: options)
		let hasHeading = blocks.contains { if case .heading = $0 { return true }; return false }
		#expect(!hasHeading)
	}

	@Test func strict_spaceVariantStillWorks() {
		let options = MarkdownOptions(headingsRequireSpaceAfterHash: true)
		let blocks = MarkdownBlockParser.parse("## Heading", options: options)
		guard case .heading(let level, _, _) = blocks.first else {
			Issue.record("Expected heading"); return
		}
		#expect(level == 2)
	}

	@Test func lenient_noSpaceBecomesHeading() {
		let options = MarkdownOptions(headingsRequireSpaceAfterHash: false)
		let blocks = MarkdownBlockParser.parse("##Heading", options: options)
		guard case .heading(let level, let content, _) = blocks.first else {
			Issue.record("Expected heading, got \(blocks)"); return
		}
		#expect(level == 2)
		#expect(String(content.characters) == "Heading")
	}

	@Test func lenient_preservesExistingSpace() {
		// `## Heading` already has a space — must not get a second one.
		let options = MarkdownOptions(headingsRequireSpaceAfterHash: false)
		let blocks = MarkdownBlockParser.parse("## Heading", options: options)
		guard case .heading(_, let content, _) = blocks.first else {
			Issue.record("Expected heading"); return
		}
		#expect(String(content.characters) == "Heading")
	}

	@Test func lenient_handlesAllSixLevels() {
		let options = MarkdownOptions(headingsRequireSpaceAfterHash: false)
		let input = "#A\n##B\n###C\n####D\n#####E\n######F"
		let blocks = MarkdownBlockParser.parse(input, options: options)
		let levels = blocks.compactMap { if case .heading(let level, _, _) = $0 { return level }; return nil }
		#expect(levels == [1, 2, 3, 4, 5, 6])
	}

	@Test func lenient_sevenHashesIsNotAHeading() {
		// CommonMark: more than 6 `#` is not a heading. Lenient mode shouldn't
		// promote `#######Foo` to a heading either.
		let options = MarkdownOptions(headingsRequireSpaceAfterHash: false)
		let blocks = MarkdownBlockParser.parse("#######Foo", options: options)
		let hasHeading = blocks.contains { if case .heading = $0 { return true }; return false }
		#expect(!hasHeading)
	}

	@Test func lenient_skipsInsideFencedCode() {
		let options = MarkdownOptions(headingsRequireSpaceAfterHash: false)
		let input = "```\n##Inside\n```\n##Outside"
		let blocks = MarkdownBlockParser.parse(input, options: options)
		// The code block must keep `##Inside` verbatim — only the outside line
		// becomes a heading.
		guard case .codeBlock(let code, _, _, _) = blocks.first else {
			Issue.record("Expected codeBlock first"); return
		}
		#expect(code.contains("##Inside"))
		let headings = blocks.compactMap { block -> String? in
			if case .heading(_, let content, _) = block { return String(content.characters) }
			return nil
		}
		#expect(headings == ["Outside"])
	}

	@Test func lenient_doesNotTouchMidLineHashes() {
		// `An #example` mid-paragraph is not a heading candidate.
		let options = MarkdownOptions(headingsRequireSpaceAfterHash: false)
		let blocks = MarkdownBlockParser.parse("Talking about #hashtags here.", options: options)
		guard case .paragraph(let content, _, _) = blocks.first else {
			Issue.record("Expected paragraph"); return
		}
		#expect(String(content.characters).contains("#hashtags"))
	}
}
