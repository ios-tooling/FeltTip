//
//  MarkdownLinkRewriter.swift
//  FeltTip
//

import Foundation
import Markdown

public enum MarkdownLinkRewriter {
	/// Replaces the destination of the `occurrence`-th parsed link whose
	/// destination equals `currentURL`. Returns nil when the source spelling
	/// cannot be changed safely. Reference links update their shared definition.
	public static func replacingDestination(in source: String, currentURL: String, occurrence: Int, with newURL: String) -> String? {
		guard occurrence >= 0, !currentURL.isEmpty, !newURL.isEmpty else { return nil }
		let links = parsedLinks(in: source)
		let matching = links.indices.filter { equivalent(links[$0].destination, currentURL) }
		guard matching.indices.contains(occurrence) else { return nil }
		let selected = matching[occurrence]
		let link = links[selected]
		if equivalent(link.destination, newURL) { return source }
		let text = source as NSString
		let spellings = Set([currentURL, link.destination, currentURL.removingPercentEncoding].compactMap { $0 })

		func replacing(in range: NSRange, definitionOnly: Bool) -> String? {
			for spelling in spellings where !spelling.isEmpty {
				var search = range
				while search.length > 0 {
					let found = text.range(of: spelling, options: .backwards, range: search)
					guard found.location != NSNotFound else { break }
					search.length = found.location - search.location
					if definitionOnly && !followsDefinitionColon(found.location, in: text) { continue }
					let updated = text.replacingCharacters(in: found, with: newURL)
					let reparsed = parsedLinks(in: updated)
					// A label, code sample, URL prefix, or unrelated definition must
					// never count as a destination edit. Validate the actual result.
					guard reparsed.count == links.count,
						reparsed.indices.contains(selected),
						equivalent(reparsed[selected].destination, newURL) else { continue }
					return updated
				}
			}
			return nil
		}

		if let range = link.range,
		   let result = replacing(in: range, definitionOnly: false) { return result }
		// Reference definitions are not exposed as nodes by swift-markdown.
		// Consider only destination-shaped definition text, then let a full
		// parse prove that it controls the selected reference. This also covers
		// multiline definitions without confusing fenced examples with links.
		return replacing(in: NSRange(location: 0, length: text.length), definitionOnly: true)
	}

	private struct ParsedLink {
		let destination: String
		let range: NSRange?
	}

	private static func parsedLinks(in source: String) -> [ParsedLink] {
		let (_, body, bodyOffset, _) = MarkdownBlockParser.extractFrontmatter(source)
		let converter = SourceOffsetConverter(body)
		var links: [ParsedLink] = []
		func walk(_ node: any Markup) {
			if let link = node as? Markdown.Link, let destination = link.destination {
				let range = link.range.flatMap { range in
					converter.processedRange(
						lowerLine: range.lowerBound.line, lowerColumn: range.lowerBound.column,
						upperLine: range.upperBound.line, upperColumn: range.upperBound.column)
				}.map { NSRange(location: bodyOffset + $0.lowerBound, length: $0.count) }
				links.append(ParsedLink(destination: destination, range: range))
			}
			for child in node.children { walk(child) }
		}
		walk(Document(parsing: body, options: .disableSmartOpts))
		return links
	}

	private static func equivalent(_ lhs: String, _ rhs: String) -> Bool {
		if lhs == rhs { return true }
		guard let left = URL(string: lhs), let right = URL(string: rhs) else { return false }
		return left.absoluteString == right.absoluteString
	}

	private static func followsDefinitionColon(_ offset: Int, in source: NSString) -> Bool {
		var index = offset - 1
		// Angle-delimited reference destinations are valid too.
		if index >= 0, source.character(at: index) == 0x3C { index -= 1 }
		while index >= 0 {
			let unit = source.character(at: index)
			if unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D { index -= 1; continue }
			return unit == 0x3A && index > 0 && source.character(at: index - 1) == 0x5D
		}
		return false
	}
}
