//
//  Tokenizer.swift
//  MarkdownRendering
//

import SwiftUI

public struct Token {
	public let text: String
	public let color: Color
}

public enum Tokenizer {
	public static func tokenize(_ code: String) -> [Token] {
		var tokens: [Token] = []
		var remaining = Substring(code)

		while !remaining.isEmpty {
			if let token = matchToken(&remaining) {
				tokens.append(token)
			} else {
				let ch = remaining.removeFirst()
				if let last = tokens.last, last.color == .primary {
					tokens[tokens.count - 1] = Token(text: last.text + String(ch), color: .primary)
				} else {
					tokens.append(Token(text: String(ch), color: .primary))
				}
			}
		}
		return tokens
	}

	public static func highlightedText(_ code: String) -> Text {
		tokenize(code).reduce(Text("")) { result, token in
			result + Text(token.text).foregroundColor(token.color)
		}
	}

	private static func matchToken(_ s: inout Substring) -> Token? {
		if let t = matchLineComment(&s) { return t }
		if let t = matchBlockComment(&s) { return t }
		if let t = matchString(&s, quote: "\"") { return t }
		if let t = matchString(&s, quote: "'") { return t }
		if let t = matchNumber(&s) { return t }
		if let t = matchKeyword(&s) { return t }
		if let t = matchType(&s) { return t }
		return nil
	}
}
