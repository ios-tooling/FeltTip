//
//  MarkdownLinkRewriter.swift
//  FeltTip
//
//  Rewrites a link's destination in the raw Markdown source. Used by the
//  styled view's "Edit Link URL" command, which knows a link's current
//  destination and its ordinal among links sharing that destination, but not
//  where it lives in the source.
//

import Foundation

public enum MarkdownLinkRewriter {
	/// Replaces the destination of the `occurrence`-th link (0-based) whose
	/// destination equals `currentURL`, returning the rewritten source — or nil
	/// when no safe match is found (so the caller can leave the source intact).
	public static func replacingDestination(in source: String, currentURL: String, occurrence: Int, with newURL: String) -> String? {
		// The styled view reports the destination as a resolved URL string; the
		// source may hold it verbatim or percent-decoded, so try both forms.
		let candidates = [currentURL, currentURL.removingPercentEncoding].compactMap { $0 }
		for needle in candidates {
			if let result = replace(in: source, needle: needle, occurrence: occurrence, with: newURL) { return result }
		}
		return nil
	}

	private static func replace(in source: String, needle: String, occurrence: Int, with newURL: String) -> String? {
		guard !needle.isEmpty else { return nil }
		let ns = source as NSString
		let needleLength = (needle as NSString).length
		guard needleLength > 0 else { return nil }
		var searchStart = 0
		var matchIndex = 0
		while searchStart + needleLength <= ns.length {
			let found = ns.range(of: needle, options: [], range: NSRange(location: searchStart, length: ns.length - searchStart))
			guard found.location != NSNotFound else { break }
			if isDestinationContext(ns, range: found) {
				if matchIndex == occurrence {
					return ns.replacingCharacters(in: found, with: newURL)
				}
				matchIndex += 1
			}
			searchStart = found.location + max(found.length, 1)
		}
		return nil
	}

	/// A destination is the URL inside `](url)`, `(url)`, an autolink `<url>`,
	/// or a reference definition `[id]: url`. We approximate by looking at the
	/// character just before the match (skipping spaces for reference defs).
	private static func isDestinationContext(_ ns: NSString, range: NSRange) -> Bool {
		var index = range.location - 1
		guard index >= 0 else { return false }
		let prev = ns.substring(with: NSRange(location: index, length: 1))
		if prev == "(" || prev == "<" { return true }
		// Reference definition: skip the run of spaces/tabs after the colon.
		while index >= 0 {
			let char = ns.substring(with: NSRange(location: index, length: 1))
			if char == " " || char == "\t" { index -= 1; continue }
			return char == ":"
		}
		return false
	}
}
