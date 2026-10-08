//
//  InlineBuilder.swift
//  MarkdownRendering
//

import Foundation
import Markdown
import SwiftUI

public struct InlineResult: Sendable {
	public let content: InlineContent
	public let links: [LinkInfo]
}

struct InlineBuilder: MarkupWalker {
	let theme: MarkdownTheme
	let fontSize: CGFloat
	/// When set, each text run is stamped with its UTF-16 offset in the source
	/// so styled-text edits can be translated back into the Markdown.
	let sourceConverter: SourceOffsetConverter?

	init(theme: MarkdownTheme, fontSize: CGFloat, sourceConverter: SourceOffsetConverter? = nil) {
		self.theme = theme
		self.fontSize = fontSize
		self.sourceConverter = sourceConverter
	}

	// `internal` rather than `private(set)` so the linkify extension (in its
	// own file) can write to them. The whole type is internal, so dropping
	// the read/write split doesn't widen access beyond the module.
	var result = InlineContent()
	var links: [LinkInfo] = []
	/// Whether any text node could hold a bare URL (`://` or `www.`), so the
	/// common case skips materialising the plain text for the linkify passes.
	private var mayContainBareURL = false
	private var charOffset = 0
	private var bold = false
	private var italic = false
	private var underline = false
	private var strikethrough = false
	private var superscript = false
	private var subscript_ = false
	private var highlight = false
	private var kbd = false
	private var inlineCode = false
	private var currentLinkURL: URL?
	private var linkStartIndex: Int?
	private var linkStartChar: Int = 0
	private var currentAbbrTitle: String?
	private var abbrStartIndex: Int?

	mutating func build(from markup: Markup, linkifyURLs: Bool = true) -> InlineResult {
		for child in markup.children { visit(child) }
		return finalize(linkifyURLs: linkifyURLs)
	}

	mutating func finalize(linkifyURLs: Bool = true) -> InlineResult {
		if linkifyURLs, mayContainBareURL {
			// Both passes read the plain text; linkifying does not change it.
			let plainText = result.characters
			linkifyBareURLs(in: plainText)
			linkifyWWWPrefix(in: plainText)
		}
		result.coalesce()
		return InlineResult(content: result, links: links)
	}

	mutating func visitText(_ text: Markdown.Text) {
		// `Text.string` materializes a String from the node each time it is read.
		let string = text.string
		if !mayContainBareURL, Self.mayHoldBareURL(string) { mayContainBareURL = true }
		if let converter = sourceConverter, let range = text.range,
		   let fragments = converter.fragmentsAroundEscapedPipes(
			lowerLine: range.lowerBound.line, lowerColumn: range.lowerBound.column,
			upperLine: range.upperBound.line, upperColumn: range.upperBound.column,
			rendered: string) {
			for fragment in fragments {
				result.append(InlineRun(
					fragment.text, style: currentStyle,
					markdownSourceOffset: fragment.sourceOffset,
					markdownEscapedPipeSourceOffset: fragment.escapedPipeSourceOffset))
			}
			charOffset += string.count
			return
		}
		var offset: Int?
		if let converter = sourceConverter, let range = text.range {
			offset = converter.verbatimUTF16Offset(
				lowerLine: range.lowerBound.line, lowerColumn: range.lowerBound.column,
				upperLine: range.upperBound.line, upperColumn: range.upperBound.column,
				rendered: string)
		}
		result.append(InlineRun(string, style: currentStyle, markdownSourceOffset: offset))
		charOffset += string.count
	}

	/// A byte scan for `://` or a case-insensitive `www.`.
	private static func mayHoldBareURL(_ string: String) -> Bool {
		var previous: (UInt8, UInt8, UInt8) = (0, 0, 0)
		for byte in string.utf8 {
			if byte == 0x2F, previous.2 == 0x2F, previous.1 == 0x3A { return true }
			if byte == 0x2E, previous.2 | 0x20 == 0x77, previous.1 | 0x20 == 0x77, previous.0 | 0x20 == 0x77 { return true }
			previous = (previous.1, previous.2, byte)
		}
		return false
	}

	mutating func visitStrong(_ strong: Strong) {
		let prev = bold; bold = true
		descendInto(strong)
		bold = prev
	}

	mutating func visitEmphasis(_ emphasis: Emphasis) {
		let prev = italic; italic = true
		descendInto(emphasis)
		italic = prev
	}

	mutating func visitStrikethrough(_ node: Strikethrough) {
		let prev = strikethrough; strikethrough = true
		descendInto(node)
		strikethrough = prev
	}

	mutating func visitInlineCode(_ code: InlineCode) {
		var offset: Int?
		if let converter = sourceConverter, let range = code.range {
			offset = converter.verbatimInlineCodeUTF16Offset(
				lowerLine: range.lowerBound.line, lowerColumn: range.lowerBound.column,
				upperLine: range.upperBound.line, upperColumn: range.upperBound.column,
				rendered: code.code)
		}
		result.append(InlineRun(code.code, style: .monospaced, markdownSourceOffset: offset))
		charOffset += code.code.count
	}

	mutating func visitLink(_ link: Markdown.Link) {
		let start = result.runs.count
		let startChar = charOffset
		descendInto(link)
		if start < result.runs.count, let dest = link.destination, let url = URL(string: dest) {
			result.setLink(url, fromRun: start)
			links.append(LinkInfo(url: dest, characterOffset: startChar))
		}
	}

	mutating func visitImage(_ image: Markdown.Image) {
		// Images handled at block level; emit alt text as placeholder
		result.append(InlineRun(image.plainText, style: .secondary))
		charOffset += image.plainText.count
	}

	mutating func visitInlineHTML(_ html: InlineHTML) {
		let raw = html.rawHTML.trimmingCharacters(in: .whitespaces)
		let tag = raw.lowercased()

		if tag == "<br>" || tag == "<br/>" || tag == "<br />" {
			result.append(InlineRun("\n"))
			charOffset += 1
			return
		}

		// Inline <img> — emit alt text
		if tag.hasPrefix("<img") {
			let alt = HTMLAttributeParser.extractAttribute("alt", from: raw) ?? "image"
			result.append(InlineRun(alt, style: currentStyle, link: currentLinkURL))
			charOffset += alt.count
			return
		}

		// Inline <a href="..."> — start tracking link
		if tag.hasPrefix("<a "), let href = HTMLAttributeParser.extractAttribute("href", from: raw), let url = URL(string: href) {
			currentLinkURL = url
			linkStartIndex = result.runs.count
			linkStartChar = charOffset
			return
		}

		// <abbr title="..."> — start tracking abbreviation tooltip
		if tag.hasPrefix("<abbr") {
			currentAbbrTitle = HTMLAttributeParser.extractAttribute("title", from: raw)
			abbrStartIndex = result.runs.count
			return
		}

		// </abbr> — finalize the abbreviation by applying underline + tooltip
		if tag == "</abbr>" {
			if let title = currentAbbrTitle, let start = abbrStartIndex, start < result.runs.count {
				for index in start..<result.runs.count {
					result.runs[index].style.insert(.underline)
					result.runs[index].toolTip = title
				}
			}
			currentAbbrTitle = nil
			abbrStartIndex = nil
			return
		}

		// </a> — apply link to accumulated content
		if tag == "</a>" {
			if let url = currentLinkURL, let start = linkStartIndex, start < result.runs.count {
				result.setLink(url, fromRun: start)
				links.append(LinkInfo(url: url.absoluteString, characterOffset: linkStartChar))
			}
			currentLinkURL = nil
			linkStartIndex = nil
			return
		}

		// Track opening/closing tags for styling
		if tag == "<sup>" { superscript = true }
		else if tag == "</sup>" { superscript = false }
		else if tag == "<sub>" { subscript_ = true }
		else if tag == "</sub>" { subscript_ = false }
		else if tag == "<u>" { underline = true }
		else if tag == "</u>" { underline = false }
		else if tag == "<mark>" { highlight = true }
		else if tag == "</mark>" { highlight = false }
		else if tag == "<kbd>" { kbd = true }
		else if tag == "</kbd>" { kbd = false }
		else if tag == "<s>" || tag == "<del>" || tag == "<strike>" { strikethrough = true }
		else if tag == "</s>" || tag == "</del>" || tag == "</strike>" { strikethrough = false }
		else if tag == "<b>" || tag == "<strong>" { bold = true }
		else if tag == "</b>" || tag == "</strong>" { bold = false }
		else if tag == "<i>" || tag == "<em>" { italic = true }
		else if tag == "</i>" || tag == "</em>" { italic = false }
		else if tag == "<code>" { inlineCode = true }
		else if tag == "</code>" { inlineCode = false }
	}


	mutating func visitSoftBreak(_ softBreak: SoftBreak) {
		result.append(InlineRun(" "))
		charOffset += 1
	}

	mutating func visitLineBreak(_ lineBreak: LineBreak) {
		result.append(InlineRun("\n"))
		charOffset += 1
	}

	/// The flags in force for the next run. Colors are not recorded: the
	/// renderers derive them from these flags and the theme.
	private var currentStyle: InlineStyle {
		var style: InlineStyle = []
		if kbd || inlineCode { style.insert(.monospaced) }
		if bold { style.insert(.bold) }
		if italic { style.insert(.italic) }
		if underline { style.insert(.underline) }
		if strikethrough { style.insert(.strikethrough) }
		if superscript { style.insert(.superscript) }
		if subscript_ { style.insert(.subscript) }
		if highlight { style.insert(.highlight) }
		return style
	}

}
