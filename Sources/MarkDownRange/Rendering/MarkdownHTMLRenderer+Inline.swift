//
//  MarkdownHTMLRenderer+Inline.swift
//  MarkDownRange
//

import Foundation
import SwiftUI

extension MarkdownHTMLRenderer {
	/// Walks an AttributedString's runs and emits HTML that mirrors the
	/// inline traits (bold/italic/monospaced) and link attributes. Adjacent
	/// runs may produce `</strong><strong>` boundaries — valid HTML, no
	/// attempt at minimization since browsers and NSAttributedString import
	/// handle it identically.
	static func renderInline(_ attributed: AttributedString) -> String {
		var result = ""
		for run in attributed.runs {
			let substring = attributed[run.range]
			let text = escape(String(substring.characters))
			guard !text.isEmpty else { continue }

			var wrapped = text
			let traits = run.inlineFontTraits ?? []
			if traits.contains(.monospaced) { wrapped = "<code>\(wrapped)</code>" }
			if traits.contains(.italic) { wrapped = "<em>\(wrapped)</em>" }
			if traits.contains(.bold) { wrapped = "<strong>\(wrapped)</strong>" }

			if let url = run.link {
				let href = attributeValue(url.absoluteString, allowedSchemes: linkSchemes)
				wrapped = "<a href=\"\(href)\">\(wrapped)</a>"
			}
			// In editable rendering, tag each run with its source offset so the
			// contentEditable bridge can map a caret position back to the
			// Markdown source. The span wraps the whole run so its text content
			// equals the run's text (keeps the caret math simple).
			if emitSourceOffsets, let offset = run.markdownSourceOffset {
				wrapped = "<span data-s=\"\(offset)\">\(wrapped)</span>"
			}
			result += wrapped
		}
		return result
	}

	static let linkSchemes: Set<String> = ["http", "https", "mailto", "file", "tel", "sms"]
	static let imageSchemes: Set<String> = ["http", "https", "file", "data"]

	/// HTML-escapes the five characters that change meaning inside element
	/// content or attribute values.
	static func escape(_ text: String) -> String {
		var result = ""
		result.reserveCapacity(text.count)
		for ch in text {
			switch ch {
			case "&": result += "&amp;"
			case "<": result += "&lt;"
			case ">": result += "&gt;"
			case "\"": result += "&quot;"
			case "'": result += "&#39;"
			default: result.append(ch)
			}
		}
		return result
	}

	/// Escapes a value for use inside a double-quoted attribute, and
	/// substitutes `#` for the entire URL if `allowedSchemes` is supplied and
	/// the scheme isn't on it. Prevents `javascript:`/`data:` smuggling in
	/// link contexts while still letting images use `data:` URIs.
	static func attributeValue(_ value: String, allowedSchemes: Set<String>? = nil) -> String {
		let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
		if let allowedSchemes,
		   let match = trimmed.firstMatch(of: /^([A-Za-z][A-Za-z0-9+.-]*):/),
		   !allowedSchemes.contains(String(match.1).lowercased()) {
			return "#"
		}
		return escape(value)
	}
}
