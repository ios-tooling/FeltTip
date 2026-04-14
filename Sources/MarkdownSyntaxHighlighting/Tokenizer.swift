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
		var plainStart: String.Index?

		while !remaining.isEmpty {
			let before = remaining.startIndex
			if let token = matchToken(&remaining) {
				if let start = plainStart {
					tokens.append(Token(text: String(code[start..<before]), color: .primary))
					plainStart = nil
				}
				tokens.append(token)
			} else {
				if plainStart == nil { plainStart = remaining.startIndex }
				remaining.removeFirst()
			}
		}
		if let start = plainStart {
			tokens.append(Token(text: String(code[start..<code.endIndex]), color: .primary))
		}
		return tokens
	}

	public static func highlightedText(_ code: String) -> Text {
		coalesce(tokenize(code)).reduce(Text("")) { result, token in
			result + Text(token.text).foregroundColor(token.color)
		}
	}

	/// Merge consecutive tokens that share the same color to reduce Text chaining depth.
	private static func coalesce(_ tokens: [Token]) -> [Token] {
		guard var current = tokens.first else { return [] }
		var result: [Token] = []
		result.reserveCapacity(tokens.count)
		for token in tokens.dropFirst() {
			if token.color == current.color {
				current = Token(text: current.text + token.text, color: current.color)
			} else {
				result.append(current)
				current = token
			}
		}
		result.append(current)
		return result
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
