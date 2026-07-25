//
//  MarkdownHTMLRenderer+Inline.swift
//  MarkDownRange
//

import Foundation
import SwiftUI

extension MarkdownHTMLRenderer {
	/// Walks an AttributedString's runs and emits HTML that mirrors the
	/// inline traits (bold/italic/monospaced), strikethrough, and link
	/// attributes. Adjacent
	/// runs may produce `</strong><strong>` boundaries — valid HTML, no
	/// attempt at minimization since browsers and NSAttributedString import
	/// handle it identically.
	static func renderInline(_ attributed: AttributedString) -> String {
		var result = ""
		// Append tags directly instead of rewrapping each run's string per
		// formatting layer — the latter reallocates the growing run string once
		// per trait/link/span, which dominated HTML generation on inline-heavy
		// documents. Nesting (outer→inner): span > a > strong > em > code.
		for run in attributed.runs {
			// A hard line break arrives as a newline in the run text (which the
			// NSTextView path renders literally). HTML collapses that to a
			// space, so the break vanished from the styled view; it needs a
			// <br>. Breaks are their own unstamped run, so replacing the
			// character leaves every stamped run's text — and so every source
			// offset — untouched.
			let text = withLineBreakElements(escape(String(attributed[run.range].characters)))
			guard !text.isEmpty else { continue }
			let traits = run.inlineFontTraits ?? []
			let offset = emitSourceOffsets ? run.markdownSourceOffset : nil
			if let offset { result += "<span data-s=\"\(offset)\">" }
			if let url = run.link {
				result += "<a href=\"\(attributeValue(url.absoluteString, allowedSchemes: linkSchemes))\">"
			}
			let struck = run.strikethroughStyle != nil
			if traits.contains(.bold) { result += "<strong>" }
			if traits.contains(.italic) { result += "<em>" }
			if struck { result += "<del>" }
			if traits.contains(.monospaced) { result += "<code>" }
			result += text
			if traits.contains(.monospaced) { result += "</code>" }
			if struck { result += "</del>" }
			if traits.contains(.italic) { result += "</em>" }
			if traits.contains(.bold) { result += "</strong>" }
			if run.link != nil { result += "</a>" }
			if offset != nil { result += "</span>" }
		}
		return result
	}

	/// Hard line breaks as `<br>`. Most runs hold no newline at all, so the
	/// scan short-circuits before any allocation.
	static func withLineBreakElements(_ escaped: String) -> String {
		guard escaped.utf8.contains(0x0A) else { return escaped }
		return escaped.replacingOccurrences(of: "\n", with: "<br>")
	}

	static let linkSchemes: Set<String> = ["http", "https", "mailto", "file", "tel", "sms"]
	static let imageSchemes: Set<String> = ["http", "https", "file", "data"]

	/// HTML-escapes the five characters that change meaning inside element
	/// content or attribute values.
	static func escape(_ text: String) -> String {
		// Fast path: most runs contain none of the five special characters, so
		// skip the per-character rebuild entirely.
		if !text.utf8.contains(where: { $0 == 0x26 || $0 == 0x3C || $0 == 0x3E || $0 == 0x22 || $0 == 0x27 }) {
			return text
		}
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
		if let allowedSchemes, let scheme = schemePrefix(of: value), !allowedSchemes.contains(scheme) {
			return "#"
		}
		return escape(value)
	}

	/// The lowercased URL scheme if `value` begins with one
	/// (`ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) ":"`), skipping leading
	/// whitespace; nil for scheme-less (relative) values. Hand-scanned rather
	/// than a regex, which ran per-link and dominated HTML generation on
	/// link-heavy documents.
	static func schemePrefix(of value: String) -> String? {
		var scheme = ""
		var started = false
		for scalar in value.unicodeScalars {
			let c = scalar.value
			if !started {
				if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { continue }   // leading whitespace
				guard (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) else { return nil }   // must start ALPHA
			} else if c == 0x3A {
				return scheme   // ':'
			} else if !((c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x2B || c == 0x2D || c == 0x2E) {
				return nil   // non-scheme char before ':'
			}
			started = true
			let lower = (c >= 0x41 && c <= 0x5A) ? c + 0x20 : c
			scheme.unicodeScalars.append(Unicode.Scalar(lower)!)
		}
		return nil
	}
}
