import Testing
@testable import MarkDownRange

@Suite struct IndentedCodeTests {
	@Test func fourSpaceIndentedCode() {
		let md = "Paragraph\n\n    code line 1\n    code line 2\n\nAnother paragraph"
		let blocks = MarkdownBlockParser.parse(md)
		let codeBlocks = blocks.filter { if case .codeBlock = $0 { return true }; return false }
		#expect(codeBlocks.count == 1)
		if case .codeBlock(let code, let lang, _, _) = codeBlocks.first {
			#expect(code.contains("code line 1"))
			#expect(code.contains("code line 2"))
			#expect(lang == nil, "Indented code blocks have no language")
		}
	}

	@Test func tabIndentedCode() {
		let md = "Text\n\n\tindented with tab\n\nMore text"
		let blocks = MarkdownBlockParser.parse(md)
		let codeBlocks = blocks.filter { if case .codeBlock = $0 { return true }; return false }
		#expect(codeBlocks.count == 1)
	}

	@Test func fencedCodeBlockStillWorks() {
		let md = """
		```swift
		let x = 1
		```
		"""
		let blocks = MarkdownBlockParser.parse(md)
		guard case .codeBlock(let code, let lang, _, _) = blocks.first else {
			Issue.record("Expected codeBlock"); return
		}
		#expect(code.contains("let x = 1"))
		#expect(lang == "swift")
	}

	@Test func indentedCodePreservesWhitespace() {
		let md = "Text\n\n    line 1\n      line 2 indented\n    line 3\n\nEnd"
		let blocks = MarkdownBlockParser.parse(md)
		let codeBlocks = blocks.filter { if case .codeBlock = $0 { return true }; return false }
		#expect(codeBlocks.count == 1)
		if case .codeBlock(let code, _, _, _) = codeBlocks.first {
			#expect(code.contains("  line 2 indented"), "Extra indentation should be preserved")
		}
	}
}
