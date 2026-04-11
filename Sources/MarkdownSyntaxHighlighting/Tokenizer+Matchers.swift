//
//  Tokenizer+Matchers.swift
//  MarkdownRendering
//

import SwiftUI

extension Tokenizer {
	static func matchLineComment(_ s: inout Substring) -> Token? {
		guard s.hasPrefix("//") || s.hasPrefix("#") && !s.hasPrefix("#!") else { return nil }
		let end = s.firstIndex(of: "\n") ?? s.endIndex
		let text = String(s[s.startIndex..<end])
		s = s[end...]
		return Token(text: text, color: .gray)
	}

	static func matchBlockComment(_ s: inout Substring) -> Token? {
		guard s.hasPrefix("/*") else { return nil }
		guard let endRange = s.range(of: "*/") else {
			let text = String(s); s = s[s.endIndex...]
			return Token(text: text, color: .gray)
		}
		let text = String(s[s.startIndex...endRange.upperBound])
		s = s[endRange.upperBound...]
		return Token(text: text, color: .gray)
	}

	static func matchString(_ s: inout Substring, quote: Character) -> Token? {
		guard s.first == quote else { return nil }
		var i = s.index(after: s.startIndex)
		while i < s.endIndex {
			if s[i] == "\\" { i = s.index(after: i); if i < s.endIndex { i = s.index(after: i) }; continue }
			if s[i] == quote { i = s.index(after: i); break }
			if s[i] == "\n" { break }
			i = s.index(after: i)
		}
		let text = String(s[s.startIndex..<i])
		s = s[i...]
		return Token(text: text, color: Color(.systemRed))
	}

	static func matchNumber(_ s: inout Substring) -> Token? {
		guard let first = s.first, first.isNumber || (first == "." && s.dropFirst().first?.isNumber == true) else { return nil }
		let prev = s.startIndex == s.base.startIndex ? nil : s.base[s.base.index(before: s.startIndex)]
		if let prev, prev.isLetter || prev == "_" { return nil }
		var i = s.startIndex
		while i < s.endIndex, s[i].isNumber || s[i] == "." || s[i] == "x" || s[i] == "X"
			|| (s[i].isHexDigit && s.hasPrefix("0x")) { i = s.index(after: i) }
		let text = String(s[s.startIndex..<i])
		s = s[i...]
		return Token(text: text, color: Color(.systemBlue))
	}

	static func matchKeyword(_ s: inout Substring) -> Token? {
		guard let first = s.first, first.isLetter || first == "_" || first == "@" else { return nil }
		var i = s.startIndex
		while i < s.endIndex, s[i].isLetter || s[i].isNumber || s[i] == "_" { i = s.index(after: i) }
		let word = String(s[s.startIndex..<i])
		guard keywords.contains(word) else { return nil }
		let prev = s.startIndex == s.base.startIndex ? nil : s.base[s.base.index(before: s.startIndex)]
		if let prev, prev.isLetter || prev == "_" { return nil }
		s = s[i...]
		return Token(text: word, color: Color(.systemPurple))
	}

	static func matchType(_ s: inout Substring) -> Token? {
		guard let first = s.first, first.isUppercase else { return nil }
		var i = s.startIndex
		while i < s.endIndex, s[i].isLetter || s[i].isNumber || s[i] == "_" { i = s.index(after: i) }
		let word = String(s[s.startIndex..<i])
		guard word.count > 1 else { return nil }
		let prev = s.startIndex == s.base.startIndex ? nil : s.base[s.base.index(before: s.startIndex)]
		if let prev, prev.isLetter || prev == "_" { return nil }
		s = s[i...]
		return Token(text: word, color: Color(.systemTeal))
	}

	private static let keywords: Set<String> = [
		"func", "var", "let", "if", "else", "for", "while", "return", "import", "class",
		"struct", "enum", "protocol", "extension", "guard", "switch", "case", "default",
		"break", "continue", "self", "Self", "true", "false", "nil", "try", "catch",
		"throw", "throws", "async", "await", "public", "private", "internal", "static",
		"override", "init", "deinit", "where", "in", "as", "is", "some", "any",
		"def", "elif", "from", "pass", "with", "yield", "lambda", "except", "finally",
		"const", "function", "new", "this", "typeof", "instanceof", "void", "null",
		"undefined", "export", "require", "module", "int", "float", "double", "char",
		"bool", "string", "println", "print", "val", "fn", "mut", "pub", "impl", "trait",
		"use", "mod", "type", "interface", "abstract", "final", "package", "do", "done",
		"then", "fi", "echo", "exit", "readonly", "declare",
		"@State", "@Binding", "@Published", "@Observable", "@MainActor", "@Environment",
	]
}
