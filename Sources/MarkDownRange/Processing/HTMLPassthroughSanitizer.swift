//
//  HTMLPassthroughSanitizer.swift
//  MarkDownRange
//
//  Markdown lets raw HTML through by design, and the renderer emitted HTML
//  blocks verbatim — so a `<script>` in an opened document executed inside the
//  page, with the edit bridge's message handler in reach, and an `onerror=` on
//  any tag did the same. A document is untrusted input: strip the executable
//  and remote-loading surface, keep the formatting HTML people actually write.
//
//  Deliberately conservative about *shape*: a tag whose attributes are all
//  allowed is copied through byte for byte, so sanitizing never reformats
//  anyone's markup. Anything it can't parse is escaped rather than trusted.
//

import Foundation

enum HTMLPassthroughSanitizer {
	/// Elements dropped along with everything inside them: they either execute
	/// code or load a document of their own.
	static let droppedWithContent: Set<String> = [
		"script", "iframe", "object", "embed", "applet", "frame", "frameset",
		"noembed", "noframes",
	]

	/// Elements dropped on their own: they re-point or reload the page around
	/// the content rather than adding any.
	static let droppedTags: Set<String> = ["base", "meta", "link"]

	/// Attributes carrying a URL, checked against the scheme allow-list.
	static let urlAttributes: Set<String> = [
		"href", "src", "srcset", "poster", "data", "background", "action",
		"formaction", "cite", "longdesc", "xlink:href", "ping",
	]

	/// Schemes a document may point at. Everything script-bearing (`javascript:`,
	/// `vbscript:`) and `data:` documents are excluded; relative URLs, which
	/// carry no scheme at all, stay allowed.
	static let allowedSchemes: Set<String> = [
		"http", "https", "mailto", "file", "tel", "sms", "markerlocalres",
	]

	static func sanitize(_ html: String) -> String {
		var result = ""
		result.reserveCapacity(html.count)
		var scanner = Scanner(html)
		while let character = scanner.peek() {
			guard character == "<" else {
				result.append(character)
				scanner.advance()
				continue
			}
			if scanner.matches("<!--") {
				result += scanner.consumeComment()      // comments can't execute
				continue
			}
			if scanner.matches("<!") || scanner.matches("<?") {
				_ = scanner.consumeThrough(">")          // doctype / processing instruction
				continue
			}
			guard let tag = scanner.consumeTag() else {
				result += "&lt;"                        // a stray "<" is text
				scanner.advance()
				continue
			}
			let name = tag.name.lowercased()
			if droppedWithContent.contains(name) {
				if !tag.isClosing, !tag.isSelfClosing { scanner.skipToClosingTag(named: name) }
				continue
			}
			if droppedTags.contains(name) { continue }
			result += rewrite(tag)
		}
		return result
	}

	// MARK: Tags

	struct Tag {
		var name: String
		var isClosing: Bool
		var isSelfClosing: Bool
		var attributes: [(name: String, value: String?)]
		/// The tag exactly as it appeared, re-emitted when nothing is stripped.
		var verbatim: String
	}

	private static func rewrite(_ tag: Tag) -> String {
		let kept = tag.attributes.filter { allows(attribute: $0.name.lowercased(), value: $0.value) }
		guard kept.count != tag.attributes.count else { return tag.verbatim }
		var result = "<" + (tag.isClosing ? "/" : "") + tag.name
		for attribute in kept {
			result += " " + attribute.name
			if let value = attribute.value {
				result += "=\"" + value
					.replacingOccurrences(of: "&", with: "&amp;")
					.replacingOccurrences(of: "\"", with: "&quot;") + "\""
			}
		}
		return result + (tag.isSelfClosing ? " />" : ">")
	}

	private static func allows(attribute name: String, value: String?) -> Bool {
		// Event handlers, in any casing, on any element.
		if name.hasPrefix("on") { return false }
		// SMIL animation can otherwise install a handler after the fact.
		if name == "attributename", value?.lowercased().hasPrefix("on") == true { return false }
		// An inline document of its own, exempt from everything above.
		if name == "srcdoc" { return false }
		guard urlAttributes.contains(name), let value else { return true }
		return allows(url: value)
	}

	static func allows(url: String) -> Bool {
		let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
			.replacingOccurrences(of: "\t", with: "")
			.replacingOccurrences(of: "\n", with: "")
		// Scheme-relative ("//host/x") inherits the page's scheme; the page is
		// loaded from our own resource scheme or from nothing, so treat it as
		// relative and allow it.
		guard let colon = trimmed.firstIndex(of: ":") else { return true }
		if let slash = trimmed.firstIndex(of: "/"), slash < colon { return true }   // path with a colon in it
		if let hash = trimmed.firstIndex(of: "#"), hash < colon { return true }
		if let question = trimmed.firstIndex(of: "?"), question < colon { return true }
		let scheme = trimmed[trimmed.startIndex..<colon].lowercased()
		if scheme == "data" {
			// Images only, and never a document that could carry script.
			return trimmed.lowercased().hasPrefix("data:image/") && !trimmed.lowercased().contains("svg")
		}
		return allowedSchemes.contains(scheme)
	}

	// MARK: Scanning

	private struct Scanner {
		private let characters: [Character]
		private var index = 0

		init(_ string: String) { characters = Array(string) }

		func peek(_ offset: Int = 0) -> Character? {
			let target = index + offset
			return target < characters.count ? characters[target] : nil
		}

		mutating func advance(_ count: Int = 1) { index = min(index + count, characters.count) }

		func matches(_ prefix: String) -> Bool {
			let wanted = Array(prefix)
			guard index + wanted.count <= characters.count else { return false }
			return Array(characters[index..<(index + wanted.count)]) == wanted
		}

		mutating func consumeThrough(_ terminator: Character) -> String {
			var text = ""
			while let character = peek() {
				text.append(character)
				advance()
				if character == terminator { break }
			}
			return text
		}

		mutating func consumeComment() -> String {
			var text = ""
			while let character = peek() {
				text.append(character)
				advance()
				if text.hasSuffix("-->") { break }
			}
			return text
		}

		/// Parses a tag starting at "<". Returns nil (leaving the scanner where
		/// it was) when what follows isn't a tag name.
		mutating func consumeTag() -> Tag? {
			let start = index
			advance()                                  // "<"
			var isClosing = false
			if peek() == "/" { isClosing = true; advance() }
			var name = ""
			while let character = peek(), character.isLetter || character.isNumber || character == "-" || character == ":" {
				name.append(character)
				advance()
			}
			guard !name.isEmpty else { index = start; return nil }
			var attributes: [(name: String, value: String?)] = []
			var isSelfClosing = false
			while true {
				skipWhitespace()
				guard let character = peek() else { break }         // unterminated tag
				if character == ">" { advance(); break }
				if character == "/" , peek(1) == ">" { isSelfClosing = true; advance(2); break }
				if character == "/" { advance(); continue }
				guard let attribute = consumeAttribute() else { advance(); continue }
				attributes.append(attribute)
			}
			let verbatim = String(characters[start..<index])
			return Tag(name: name, isClosing: isClosing, isSelfClosing: isSelfClosing,
					   attributes: attributes, verbatim: verbatim)
		}

		private mutating func consumeAttribute() -> (name: String, value: String?)? {
			var name = ""
			while let character = peek(), !character.isWhitespace, character != "=", character != ">", character != "/" {
				name.append(character)
				advance()
			}
			guard !name.isEmpty else { return nil }
			skipWhitespace()
			guard peek() == "=" else { return (name, nil) }
			advance()
			skipWhitespace()
			guard let quote = peek() else { return (name, nil) }
			var value = ""
			if quote == "\"" || quote == "'" {
				advance()
				while let character = peek(), character != quote {
					value.append(character)
					advance()
				}
				advance()                                          // closing quote
			} else {
				while let character = peek(), !character.isWhitespace, character != ">" {
					value.append(character)
					advance()
				}
			}
			return (name, decodeEntities(value))
		}

		/// Values are compared against the scheme allow-list, so an encoded
		/// "java&#115;cript:" must not slip past it.
		private func decodeEntities(_ value: String) -> String {
			guard value.contains("&") else { return value }
			var result = value
			for (entity, replacement) in [("&colon;", ":"), ("&#58;", ":"), ("&#x3a;", ":"), ("&#X3A;", ":"),
										  ("&NewLine;", ""), ("&Tab;", ""), ("&amp;", "&")] {
				result = result.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
			}
			// Numeric references for the letters of a scheme (java&#115;cript).
			while let range = result.range(of: "&#[xX]?[0-9a-fA-F]+;?", options: .regularExpression) {
				let body = result[range].dropFirst(2)
				let digits = body.hasPrefix("x") || body.hasPrefix("X") ? String(body.dropFirst()) : String(body)
				let radix = body.hasPrefix("x") || body.hasPrefix("X") ? 16 : 10
				guard let code = UInt32(digits.hasSuffix(";") ? String(digits.dropLast()) : digits, radix: radix),
					  let scalar = Unicode.Scalar(code) else { break }
				result.replaceSubrange(range, with: String(Character(scalar)))
			}
			return result
		}

		mutating func skipWhitespace() {
			while let character = peek(), character.isWhitespace { advance() }
		}

		/// Drops everything up to and including `</name>`, or to the end when
		/// the element is never closed.
		mutating func skipToClosingTag(named name: String) {
			while index < characters.count {
				guard peek() == "<", peek(1) == "/" else { advance(); continue }
				let start = index
				advance(2)
				var closing = ""
				while let character = peek(), character.isLetter || character.isNumber || character == "-" {
					closing.append(character)
					advance()
				}
				if closing.lowercased() == name {
					_ = consumeThrough(">")
					return
				}
				index = start + 2
			}
		}
	}
}
