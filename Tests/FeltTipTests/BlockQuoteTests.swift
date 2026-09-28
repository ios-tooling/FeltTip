import Testing
@testable import FeltTip

@Suite struct BlockQuoteTests {
	@Test func simpleBlockQuote() {
		let blocks = MarkdownBlockParser.parse("> This is a quote")
		guard case .blockquote(let children, _) = blocks.first else {
			Issue.record("Expected blockquote"); return
		}
		#expect(!children.isEmpty)
		if case .paragraph(let content, _, _) = children.first {
			#expect(String(content.characters).contains("quote"))
		}
	}

	@Test func multilineBlockQuote() {
		let md = "> Line one\n> Line two\n> Line three"
		let blocks = MarkdownBlockParser.parse(md)
		guard case .blockquote(let children, _) = blocks.first else {
			Issue.record("Expected blockquote"); return
		}
		#expect(!children.isEmpty)
	}

	@Test func nestedBlockQuote() {
		let md = "> Outer\n>\n> > Inner"
		let blocks = MarkdownBlockParser.parse(md)
		guard case .blockquote(let outer, _) = blocks.first else {
			Issue.record("Expected blockquote"); return
		}
		let hasNestedQuote = outer.contains { if case .blockquote = $0 { return true }; return false }
		#expect(hasNestedQuote)
	}

	@Test func blockQuoteWithCode() {
		let md = "> ```\n> code\n> ```"
		let blocks = MarkdownBlockParser.parse(md)
		guard case .blockquote(let children, _) = blocks.first else {
			Issue.record("Expected blockquote"); return
		}
		let hasCode = children.contains { if case .codeBlock = $0 { return true }; return false }
		#expect(hasCode)
	}

	@Test func blockQuoteWithList() {
		let md = "> - Item 1\n> - Item 2"
		let blocks = MarkdownBlockParser.parse(md)
		guard case .blockquote(let children, _) = blocks.first else {
			Issue.record("Expected blockquote"); return
		}
		let hasList = children.contains { if case .unorderedList = $0 { return true }; return false }
		#expect(hasList)
	}
}
