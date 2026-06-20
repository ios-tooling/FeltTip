//
//  InlineBuilder.swift
//  MarkdownRendering
//

import Foundation
import Markdown
import SwiftUI

public struct InlineResult: Sendable {
	public let attributed: AttributedString
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
	var result = AttributedString()
	var links: [LinkInfo] = []
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
	private var linkStartIndex: AttributedString.Index?
	private var linkStartChar: Int = 0
	private var currentAbbrTitle: String?
	private var abbrStartIndex: AttributedString.Index?

	mutating func build(from markup: Markup, linkifyURLs: Bool = true) -> InlineResult {
		for child in markup.children { visit(child) }
		return finalize(linkifyURLs: linkifyURLs)
	}

	mutating func finalize(linkifyURLs: Bool = true) -> InlineResult {
		if linkifyURLs {
			linkifyBareURLs()
			linkifyWWWPrefix()
		}
		return InlineResult(attributed: result, links: links)
	}

	mutating func visitText(_ text: Markdown.Text) {
		var str = AttributedString(text.string)
		applyCurrentStyle(&str)
		if let converter = sourceConverter, let loc = text.range?.lowerBound,
		   let offset = converter.utf16Offset(line: loc.line, column: loc.column) {
			str.markdownSourceOffset = offset
		}
		result += str
		charOffset += text.string.count
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
		var str = AttributedString(code.code)
		str.font = .system(size: fontSize, design: .monospaced)
		str.foregroundColor = theme.codeForeground
		str.backgroundColor = theme.codeBackground
		str.inlineFontTraits = .monospaced
		result += str
		charOffset += code.code.count
	}

	mutating func visitLink(_ link: Markdown.Link) {
		let start = result.endIndex
		let startChar = charOffset
		descendInto(link)
		if start < result.endIndex, let dest = link.destination, let url = URL(string: dest) {
			result[start..<result.endIndex].link = url
			result[start..<result.endIndex].foregroundColor = theme.linkColor
			links.append(LinkInfo(url: dest, characterOffset: startChar))
		}
	}

	mutating func visitImage(_ image: Markdown.Image) {
		// Images handled at block level; emit alt text as placeholder
		var str = AttributedString(image.plainText)
		str.foregroundColor = theme.secondaryColor
		result += str
		charOffset += image.plainText.count
	}

	mutating func visitInlineHTML(_ html: InlineHTML) {
		let raw = html.rawHTML.trimmingCharacters(in: .whitespaces)
		let tag = raw.lowercased()

		if tag == "<br>" || tag == "<br/>" || tag == "<br />" {
			result += AttributedString("\n")
			charOffset += 1
			return
		}

		// Inline <img> — emit alt text
		if tag.hasPrefix("<img") {
			let alt = HTMLAttributeParser.extractAttribute("alt", from: raw) ?? "image"
			var str = AttributedString(alt)
			applyCurrentStyle(&str)
			if let url = currentLinkURL { str.link = url }
			result += str
			charOffset += alt.count
			return
		}

		// Inline <a href="..."> — start tracking link
		if tag.hasPrefix("<a "), let href = HTMLAttributeParser.extractAttribute("href", from: raw), let url = URL(string: href) {
			currentLinkURL = url
			linkStartIndex = result.endIndex
			linkStartChar = charOffset
			return
		}

		// <abbr title="..."> — start tracking abbreviation tooltip
		if tag.hasPrefix("<abbr") {
			currentAbbrTitle = HTMLAttributeParser.extractAttribute("title", from: raw)
			abbrStartIndex = result.endIndex
			return
		}

		// </abbr> — finalize the abbreviation by applying underline + tooltip
		if tag == "</abbr>" {
			if let title = currentAbbrTitle, let start = abbrStartIndex, start < result.endIndex {
				result[start..<result.endIndex].underlineStyle = .single
				#if canImport(AppKit)
				result[start..<result.endIndex].toolTip = title
				#endif
			}
			currentAbbrTitle = nil
			abbrStartIndex = nil
			return
		}

		// </a> — apply link to accumulated content
		if tag == "</a>" {
			if let url = currentLinkURL, let start = linkStartIndex, start < result.endIndex {
				result[start..<result.endIndex].link = url
				result[start..<result.endIndex].foregroundColor = theme.linkColor
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
		result += AttributedString(" ")
		charOffset += 1
	}

	mutating func visitLineBreak(_ lineBreak: LineBreak) {
		result += AttributedString("\n")
		charOffset += 1
	}

	private mutating func applyCurrentStyle(_ str: inout AttributedString) {
		if kbd || inlineCode {
			str.font = .system(size: fontSize, design: .monospaced)
			str.foregroundColor = theme.codeForeground
			str.backgroundColor = theme.codeBackground
		} else {
			var font = Font.system(size: superscript || subscript_ ? fontSize * 0.75 : fontSize)
			if bold { font = font.bold() }
			if italic { font = font.italic() }
			str.font = font
			// Intentionally NOT setting str.foregroundColor here. Pre-painting
			// every run with theme.textColor caused the consuming appender's
			// defaultColor (e.g. headingColor for headings) to be overridden,
			// which made bold-in-heading color and heading accent invisible.
		}
		if underline { str.underlineStyle = .single }
		if strikethrough { str.strikethroughStyle = .single }
		if superscript { str.baselineOffset = fontSize * 0.3 }
		if subscript_ { str.baselineOffset = -(fontSize * 0.2) }
		if highlight { str.backgroundColor = .yellow.opacity(0.3) }

		// Mirror the inline traits in a custom attribute so the NSAttributedString
		// converter can reconstruct an NSFont with matching traits — SwiftUI's
		// Font is opaque, so we can't extract bold/italic from it directly.
		var traits: InlineFontTraits = []
		if bold { traits.insert(.bold) }
		if italic { traits.insert(.italic) }
		if kbd || inlineCode { traits.insert(.monospaced) }
		if !traits.isEmpty { str.inlineFontTraits = traits }
	}

}
