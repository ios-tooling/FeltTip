//
//  MarkdownHTMLRenderer+Inline.swift
//  FeltTip
//

import Foundation
import SwiftUI

extension MarkdownHTMLRenderer {
	/// Walks the inline runs and emits HTML that mirrors their style flags
	/// and links. Adjacent runs may produce `</strong><strong>` boundaries —
	/// valid HTML, no attempt at minimization since browsers and
	/// NSAttributedString import handle it identically.
	static func renderInline(_ content: InlineContent) -> String {
		var result = ""
		// Append tags directly instead of rewrapping each run's string per
		// formatting layer — the latter reallocates the growing run string once
		// per trait/link/span, which dominated HTML generation on inline-heavy
		// documents. Nesting (outer→inner):
		// span > a > strong > em > u > del > mark > sup/sub > code.
		for run in content.runs {
			// A hard line break arrives as a newline in the run text (which the
			// NSTextView path renders literally). HTML collapses that to a
			// space, so the break vanished from the styled view; it needs a
			// <br>. Breaks are their own unstamped run, so replacing the
			// character leaves every stamped run's text — and so every source
			// offset — untouched.
			let text = withLineBreakElements(escape(run.text))
			guard !text.isEmpty else { continue }
			let style = run.style
			let offset = emitSourceOffsets ? run.markdownSourceOffset : nil
			let escapedPipeOffset = emitSourceOffsets ? run.markdownEscapedPipeSourceOffset : nil
			if let offset { result += "<span data-s=\"\(offset)\">" }
			if let escapedPipeOffset { result += "<span data-md-escaped-pipe-s=\"\(escapedPipeOffset)\">" }
			if let url = run.link {
				result += "<a \(linkAttributes(for: url))>"
			}
			let struck = style.contains(.strikethrough)
			let underlined = style.contains(.underline)
			let highlighted = style.contains(.highlight) && !style.contains(.monospaced)
			if style.contains(.bold) { result += "<strong>" }
			if style.contains(.italic) { result += "<em>" }
			if underlined { result += "<u>" }
			if struck { result += "<del>" }
			if highlighted { result += "<mark>" }
			if style.isSuperscript { result += "<sup>" }
			if style.contains(.subscript) { result += "<sub>" }
			if style.contains(.monospaced) { result += "<code>" }
			result += text
			if style.contains(.monospaced) { result += "</code>" }
			if style.contains(.subscript) { result += "</sub>" }
			if style.isSuperscript { result += "</sup>" }
			if highlighted { result += "</mark>" }
			if struck { result += "</del>" }
			if underlined { result += "</u>" }
			if style.contains(.italic) { result += "</em>" }
			if style.contains(.bold) { result += "</strong>" }
			if run.link != nil { result += "</a>" }
			if escapedPipeOffset != nil { result += "</span>" }
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

	/// Converts the private URLs emitted by `MarkdownPreprocessor` into real
	/// in-page anchors. Keeping the schemes out of `linkSchemes` is deliberate:
	/// arbitrary custom schemes must still collapse to `#`, while these three
	/// known navigation markers never leave the rendered document.
	static func linkAttributes(for url: URL) -> String {
		let value = url.absoluteString
		guard let scheme = url.scheme?.lowercased() else {
			return "href=\"\(attributeValue(value, allowedSchemes: linkSchemes))\""
		}
		switch scheme {
		case "footnote":
			guard let label = footnoteLabel(in: value) else { return "href=\"#\"" }
			return "href=\"#feltip-footnote-\(attributeValue(label))\" id=\"feltip-footnote-ref-\(attributeValue(label))\""
		case "footnote-anchor":
			guard let label = footnoteLabel(in: value) else { return "href=\"#\"" }
			return "href=\"#feltip-footnote-ref-\(attributeValue(label))\" id=\"feltip-footnote-\(attributeValue(label))\""
		case "footnote-back":
			guard let label = footnoteLabel(in: value) else { return "href=\"#\"" }
			return "href=\"#feltip-footnote-ref-\(attributeValue(label))\""
		default:
			return "href=\"\(attributeValue(value, allowedSchemes: linkSchemes))\""
		}
	}

	private static func footnoteLabel(in value: String) -> String? {
		guard let separator = value.range(of: "://"), separator.upperBound < value.endIndex else {
			return nil
		}
		return String(value[separator.upperBound...])
	}

	/// HTML-escapes the five characters that change meaning inside element
	/// content or attribute values.
	static func escape(_ text: String) -> String {
		// Fast path: most runs contain none of the five special characters, so
		// skip the per-character rebuild entirely.
		if !text.utf8.contains(where: { $0 == 0x26 || $0 == 0x3C || $0 == 0x3E || $0 == 0x22 || $0 == 0x27 }) {
			return text
		}
		// Byte-level rebuild: the five escapes are ASCII, so splicing their
		// bytes between untouched runs yields valid UTF-8 without touching
		// grapheme clusters. `text.count` alone was a full grapheme count.
		var text = text
		return text.withUTF8 { bytes in
			var output: [UInt8] = []
			output.reserveCapacity(bytes.count + 16)
			var runStart = 0
			for i in 0..<bytes.count {
				let replacement: StaticString
				switch bytes[i] {
				case 0x26: replacement = "&amp;"
				case 0x3C: replacement = "&lt;"
				case 0x3E: replacement = "&gt;"
				case 0x22: replacement = "&quot;"
				case 0x27: replacement = "&#39;"
				default: continue
				}
				output.append(contentsOf: bytes[runStart..<i])
				replacement.withUTF8Buffer { output.append(contentsOf: $0) }
				runStart = i + 1
			}
			output.append(contentsOf: bytes[runStart...])
			return String(decoding: output, as: UTF8.self)
		}
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
