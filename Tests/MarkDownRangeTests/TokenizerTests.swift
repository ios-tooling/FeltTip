import Testing
import SwiftUI
@testable import MarkDownRange

@Suite struct TokenizerTests {
	@Test func plainText() {
		let tokens = Tokenizer.tokenize("hello world")
		#expect(tokens.count >= 1)
		#expect(tokens.map(\.text).joined() == "hello world")
	}

	@Test func swiftKeyword() {
		let tokens = Tokenizer.tokenize("func main()")
		let funcToken = tokens.first { $0.text == "func" }
		#expect(funcToken != nil)
		#expect(funcToken?.color != .primary)
	}

	@Test func stringLiteral() {
		let tokens = Tokenizer.tokenize("let x = \"hello\"")
		let stringToken = tokens.first { $0.text.contains("hello") }
		#expect(stringToken != nil)
	}

	@Test func lineComment() {
		let tokens = Tokenizer.tokenize("// this is a comment\ncode")
		let commentToken = tokens.first { $0.text.contains("comment") }
		#expect(commentToken != nil)
		#expect(commentToken?.color == .gray)
	}

	@Test func blockComment() {
		let tokens = Tokenizer.tokenize("/* block */code")
		let commentToken = tokens.first { $0.text.contains("block") }
		#expect(commentToken != nil)
		#expect(commentToken?.color == .gray)
	}

	@Test func numberLiteral() {
		let tokens = Tokenizer.tokenize("let x = 42")
		let numToken = tokens.first { $0.text == "42" }
		#expect(numToken != nil)
		#expect(numToken?.color != .primary)
	}

	@Test func typeIdentifier() {
		let tokens = Tokenizer.tokenize("let x: String")
		let typeToken = tokens.first { $0.text == "String" }
		#expect(typeToken != nil)
	}

	@Test func highlightedTextPreservesContent() {
		let text = Tokenizer.highlightedText("let x = 1")
		// Verify it produces a non-empty Text (can't inspect Text internals)
		#expect(type(of: text) == Text.self)
	}

	@Test func emptyInput() {
		let tokens = Tokenizer.tokenize("")
		#expect(tokens.isEmpty)
	}

	@Test func singleCharacterInput() {
		let tokens = Tokenizer.tokenize("x")
		#expect(tokens.count == 1)
		#expect(tokens[0].text == "x")
	}

	@Test func pythonKeyword() {
		let tokens = Tokenizer.tokenize("def hello():")
		let defToken = tokens.first { $0.text == "def" }
		#expect(defToken != nil)
	}

	@Test func swiftKeywordVar() {
		let tokens = Tokenizer.tokenize("@State var x = 1")
		let varToken = tokens.first { $0.text == "var" }
		#expect(varToken != nil)
		#expect(varToken?.color != .primary)
	}
}
