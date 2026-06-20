//
//  Tokenizer.swift
//  MarkdownRendering
//

import SwiftUI

/// The semantic role of a token. Drives both the SwiftUI color (NSTextView
/// path) and the CSS class emitted for HTML (webview / QuickLook / export), so
/// the two renderers stay in lockstep.
public enum TokenKind: Sendable {
	case plain, keyword, type, string, number, comment

	/// CSS class for the HTML path, or nil for plain text (no wrapping span).
	public var cssClass: String? {
		switch self {
		case .plain: return nil
		case .keyword: return "tok-keyword"
		case .type: return "tok-type"
		case .string: return "tok-string"
		case .number: return "tok-number"
		case .comment: return "tok-comment"
		}
	}
}

public struct Token {
	public let text: String
	public let kind: TokenKind

	public init(text: String, kind: TokenKind) {
		self.text = text
		self.kind = kind
	}

	public var color: Color {
		switch kind {
		case .plain: return .primary
		case .keyword: return Color(.systemPurple)
		case .type: return Color(.systemTeal)
		case .string: return Color(.systemRed)
		case .number: return Color(.systemBlue)
		case .comment: return .gray
		}
	}
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
					tokens.append(Token(text: String(code[start..<before]), kind: .plain))
					plainStart = nil
				}
				tokens.append(token)
			} else {
				if plainStart == nil { plainStart = remaining.startIndex }
				remaining.removeFirst()
			}
		}
		if let start = plainStart {
			tokens.append(Token(text: String(code[start..<code.endIndex]), kind: .plain))
		}
		return tokens
	}

	public static func highlightedText(_ code: String) -> Text {
		coalesce(tokenize(code)).reduce(Text("")) { result, token in
			result + Text(token.text).foregroundColor(token.color)
		}
	}

	/// Highlights `code` and returns one `Text` per source line, so a renderer
	/// can lay each line out as its own row — a wrapped line then shares its
	/// single line number with the continuation rows below it. Multi-line tokens
	/// (block comments, strings) keep their kind across the split, and empty
	/// lines render a space so they still occupy a row.
	public static func highlightedLines(_ code: String) -> [Text] {
		var lines: [[Token]] = [[]]
		for token in coalesce(tokenize(code)) {
			let parts = token.text.components(separatedBy: "\n")
			for (offset, part) in parts.enumerated() {
				if offset > 0 { lines.append([]) }
				if !part.isEmpty { lines[lines.count - 1].append(Token(text: part, kind: token.kind)) }
			}
		}
		return lines.map { tokens in
			guard !tokens.isEmpty else { return Text(" ") }
			return tokens.reduce(Text("")) { $0 + Text($1.text).foregroundColor($1.color) }
		}
	}

	/// Highlights `code` as an HTML fragment: each non-plain token becomes a
	/// `<span class="tok-…">`, plain runs pass through escaped. Powers the HTML
	/// renderer (webview / QuickLook / export); the CSS for the classes lives in
	/// `MarkdownHTMLRenderer`. `escape` is injected so the renderer's own
	/// escaping stays the single source of truth.
	public static func highlightedHTML(_ code: String, escape: (String) -> String) -> String {
		coalesce(tokenize(code)).reduce(into: "") { html, token in
			let text = escape(token.text)
			if let cls = token.kind.cssClass {
				html += "<span class=\"\(cls)\">\(text)</span>"
			} else {
				html += text
			}
		}
	}

	/// Merge consecutive tokens of the same kind to reduce span/Text chaining.
	private static func coalesce(_ tokens: [Token]) -> [Token] {
		guard var current = tokens.first else { return [] }
		var result: [Token] = []
		result.reserveCapacity(tokens.count)
		for token in tokens.dropFirst() {
			if token.kind == current.kind {
				current = Token(text: current.text + token.text, kind: current.kind)
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
