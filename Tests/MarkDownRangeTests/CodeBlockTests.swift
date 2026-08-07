import Testing
@testable import MarkDownRange

@Suite struct CodeBlockTests {
	@Test func fencedCodeBlock() {
		let md = "```\ncode here\n```"
		let blocks = MarkdownBlockParser.parse(md)
		guard case .codeBlock(let code, let lang, _, _) = blocks.first else {
			Issue.record("Expected codeBlock"); return
		}
		#expect(code.contains("code here"))
		#expect(lang == nil)
	}

	@Test func fencedWithLanguage() {
		let md = "```swift\nlet x = 1\n```"
		let blocks = MarkdownBlockParser.parse(md)
		guard case .codeBlock(let code, let lang, _, _) = blocks.first else {
			Issue.record("Expected codeBlock"); return
		}
		#expect(code.contains("let x = 1"))
		#expect(lang == "swift")
	}

	@Test func fencedWithTildes() {
		let md = "~~~python\nprint('hi')\n~~~"
		let blocks = MarkdownBlockParser.parse(md)
		guard case .codeBlock(_, let lang, _, _) = blocks.first else {
			Issue.record("Expected codeBlock"); return
		}
		#expect(lang == "python")
	}

	@Test func codeBlockPreservesWhitespace() {
		let md = "```\n  indented\n    more\n```"
		let blocks = MarkdownBlockParser.parse(md)
		guard case .codeBlock(let code, _, _, _) = blocks.first else {
			Issue.record("Expected codeBlock"); return
		}
		#expect(code.contains("  indented"))
		#expect(code.contains("    more"))
	}

	@Test func codeBlockPreservesBlankLines() {
		let md = "```\nline1\n\nline3\n```"
		let blocks = MarkdownBlockParser.parse(md)
		guard case .codeBlock(let code, _, _, _) = blocks.first else {
			Issue.record("Expected codeBlock"); return
		}
		#expect(code.contains("\n\n"))
	}

	@Test func multipleCodeBlocks() {
		let md = "```\nfirst\n```\n\nText\n\n```\nsecond\n```"
		let blocks = MarkdownBlockParser.parse(md)
		let codeBlocks = blocks.filter { if case .codeBlock = $0 { return true }; return false }
		#expect(codeBlocks.count == 2)
	}
}
