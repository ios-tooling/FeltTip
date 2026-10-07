//
//  WikilinkProcessor.swift
//  FeltTip
//

import Foundation

public enum WikilinkProcessor {
	/// Converts `[[Page Name]]` and `[[Page Name|Display Text]]` into
	/// markdown links with a `wikilink://` scheme.
	public static func process(_ text: String) -> String {
		guard DocumentScan.hasWikilink(in: text) else { return text }

		var result = ""
		var remaining = text[text.startIndex...]

		while let openRange = remaining.range(of: "[[") {
			// Check we're not inside a code span or code block
			result += remaining[..<openRange.lowerBound]

			let afterOpen = remaining[openRange.upperBound...]
			guard let closeRange = afterOpen.range(of: "]]") else {
				// No closing ]] — emit as-is
				result += "[["
				remaining = afterOpen
				continue
			}

			let inner = String(afterOpen[..<closeRange.lowerBound])
			guard !inner.isEmpty, !inner.contains("\n") else {
				result += "[["
				remaining = afterOpen
				continue
			}

			let (page, display): (String, String)
			if let pipeIdx = inner.firstIndex(of: "|") {
				page = String(inner[..<pipeIdx]).trimmingCharacters(in: .whitespaces)
				display = String(inner[inner.index(after: pipeIdx)...]).trimmingCharacters(in: .whitespaces)
			} else {
				page = inner.trimmingCharacters(in: .whitespaces)
				display = page
			}

			let encoded = page.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? page
			result += "[\(display)](wikilink://\(encoded))"
			remaining = afterOpen[closeRange.upperBound...]
		}

		result += remaining
		return result
	}
}
