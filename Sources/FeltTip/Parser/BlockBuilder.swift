//
//  BlockBuilder.swift
//  MarkdownRendering
//

import Foundation
import Markdown
import SwiftUI

final class CheckboxCounter: @unchecked Sendable {
	private(set) var value: Int
	init(_ value: Int = 0) { self.value = value }
	func next() -> Int { defer { value += 1 }; return value }
}

struct BlockBuilder: MarkupWalker {
	let theme: MarkdownTheme
	let fontSize: CGFloat
	let checkboxCounter: CheckboxCounter
	var linkifyURLs: Bool = true
	/// Forwarded to each InlineBuilder so text runs carry source offsets.
	let sourceConverter: SourceOffsetConverter?
	private var blocks: [MarkdownBlock] = []
	private var counter = 0

	init(theme: MarkdownTheme, fontSize: CGFloat, checkboxCounter: CheckboxCounter = CheckboxCounter(), sourceConverter: SourceOffsetConverter? = nil) {
		self.theme = theme
		self.fontSize = fontSize
		self.sourceConverter = sourceConverter
		self.checkboxCounter = checkboxCounter
	}

	mutating func build(from document: Markdown.Document, linkifyURLs: Bool = true) -> [MarkdownBlock] {
		self.linkifyURLs = linkifyURLs
		for child in document.children { visit(child) }
		return blocks
	}

	mutating func visitHeading(_ heading: Heading) {
		var builder = InlineBuilder(theme: theme, fontSize: fontSize, sourceConverter: sourceConverter)
		let inline = builder.build(from: heading, linkifyURLs: linkifyURLs)
		blocks.append(.heading(level: heading.level, content: inline.attributed, id: nextID()))
	}

	mutating func visitParagraph(_ paragraph: Paragraph) {
		let children = Array(paragraph.children)
		let paragraphCarriesOnlyImages = isImageOnly(children)
		var inlineChildren: [Markup] = []
		var pendingImages: [ImageRowItem] = []
		// Whitespace characters between the latest image and the next thing
		// we encounter. A single space *or* a single soft break (`\n`) keeps
		// the run together; anything more (two spaces, a hard break, a space
		// adjacent to a newline) breaks it. Non-whitespace nodes are treated
		// as infinite separation and terminate the row outright.
		var pendingSeparation = 0
		let rowSeparationLimit = 1

		var i = 0
		while i < children.count {
			let child = children[i]
			if let item = imageItem(from: child) {
				if !pendingImages.isEmpty, pendingSeparation > rowSeparationLimit {
					flushPendingImages(&pendingImages, paragraphIsImageOnly: paragraphCarriesOnlyImages)
				}
				if !inlineChildren.isEmpty {
					blocks.append(buildParagraph(from: inlineChildren))
					inlineChildren = []
				}
				pendingImages.append(item)
				pendingSeparation = 0
				i += 1
				continue
			}
			if let item = extractInlineHTMLImageItem(from: children, at: &i) {
				if !pendingImages.isEmpty, pendingSeparation > rowSeparationLimit {
					flushPendingImages(&pendingImages, paragraphIsImageOnly: paragraphCarriesOnlyImages)
				}
				if !inlineChildren.isEmpty {
					blocks.append(buildParagraph(from: inlineChildren))
					inlineChildren = []
				}
				pendingImages.append(item)
				pendingSeparation = 0
				continue
			}
			if !pendingImages.isEmpty, let count = whitespaceLength(of: child) {
				pendingSeparation += count
				i += 1
				continue
			}
			flushPendingImages(&pendingImages, paragraphIsImageOnly: paragraphCarriesOnlyImages)
			pendingSeparation = 0
			inlineChildren.append(child)
			i += 1
		}

		flushPendingImages(&pendingImages, paragraphIsImageOnly: paragraphCarriesOnlyImages)
		if !inlineChildren.isEmpty {
			blocks.append(buildParagraph(from: inlineChildren))
		}
	}

	private mutating func flushPendingImages(
		_ images: inout [ImageRowItem],
		paragraphIsImageOnly: Bool
	) {
		guard !images.isEmpty else { return }
		defer { images.removeAll() }
		if images.count >= 2 {
			blocks.append(.imageRow(images: images, id: nextID()))
			return
		}
		let only = images[0]
		// Promote to a captioned figure only when the paragraph contains
		// nothing but this single image AND the author supplied a title —
		// markdown form `![alt](url "caption")` or HTML `<img title="…">`.
		// The title is the explicit opt-in; alt stays for accessibility so
		// existing documents don't grow surprise captions.
		if paragraphIsImageOnly, let caption = only.title, !caption.isEmpty {
			blocks.append(.figure(image: only, caption: caption, id: nextID()))
			return
		}
		// `.image` carries no link, so a clickable single image has to ride
		// in an `.imageRow` of one — matches the HTML-form path that already
		// uses imageRow for linked images.
		if only.link != nil {
			blocks.append(.imageRow(images: [only], id: nextID()))
			return
		}
		blocks.append(.image(source: only.source, alt: only.alt, width: only.width, height: only.height, id: nextID()))
	}

	/// Extracts an image from a markdown inline node. Returns `nil` for
	/// anything that isn't a top-level image or a link wrapping a single
	/// image (`[![alt](url)](link)`), the latter being the common pattern
	/// for clickable badges authored in pure markdown.
	private func imageItem(from markup: Markup) -> ImageRowItem? {
		if let image = markup as? Markdown.Image {
			return ImageRowItem(
				source: image.source ?? "",
				alt: image.plainText,
				title: image.title
			)
		}
		if let link = markup as? Markdown.Link,
		   link.childCount == 1,
		   let inner = link.child(at: 0) as? Markdown.Image {
			let destination = link.destination.flatMap { URL(string: $0) }
			return ImageRowItem(
				source: inner.source ?? "",
				alt: inner.plainText,
				link: destination,
				title: inner.title
			)
		}
		return nil
	}

	private func isWhitespaceText(_ markup: Markup) -> Bool {
		guard let text = markup as? Markdown.Text else { return false }
		return text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	/// Whitespace "width" of a node sitting between two images in the same
	/// paragraph, in characters. `nil` for nodes that aren't whitespace (a
	/// link, emphasis, real text, etc.) — those terminate an image row
	/// outright. `SoftBreak`/`LineBreak` count their literal source widths
	/// (1 for a single `\n`, 2 for the trailing-two-spaces hard break) so
	/// "image, newline, image" stays grouped but "image, space + newline,
	/// image" or a hard break breaks the row.
	private func whitespaceLength(of markup: Markup) -> Int? {
		if markup is Markdown.SoftBreak { return 1 }
		if markup is Markdown.LineBreak { return 2 }
		guard let text = markup as? Markdown.Text else { return nil }
		let s = text.string
		guard s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
		return s.count
	}

	private func isImageOnly(_ children: [Markup]) -> Bool {
		var sawImage = false
		for child in children {
			if imageItem(from: child) != nil { sawImage = true; continue }
			if isWhitespaceText(child) { continue }
			// HTML img counts too, but allow only it — anything else (text,
			// emphasis, breaks) disqualifies the paragraph from the
			// figure/caption promotion.
			if let html = child as? InlineHTML,
			   html.rawHTML.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("<img") {
				sawImage = true
				continue
			}
			return false
		}
		return sawImage
	}

	/// Detects `<a href="..."><img src="..."/></a>` or standalone `<img>` in inline HTML nodes.
	private func extractInlineHTMLImageItem(from children: [Markup], at i: inout Int) -> ImageRowItem? {
		guard let html = children[i] as? InlineHTML else { return nil }
		let tag = html.rawHTML.trimmingCharacters(in: .whitespaces)

		// Standalone <img>
		if tag.lowercased().hasPrefix("<img"), let img = HTMLAttributeParser.extractImage(from: tag) {
			i += 1
			let title = HTMLAttributeParser.extractAttribute("title", from: tag)
			return ImageRowItem(source: img.src, alt: img.alt, width: img.width, height: img.height, title: title)
		}

		// <a href="..."> followed by <img> followed by </a>
		if tag.lowercased().hasPrefix("<a "),
		   i + 2 < children.count,
		   let imgHTML = children[i + 1] as? InlineHTML,
		   let closeHTML = children[i + 2] as? InlineHTML,
		   imgHTML.rawHTML.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("<img"),
		   closeHTML.rawHTML.trimmingCharacters(in: .whitespaces).lowercased() == "</a>" {
			let imgTag = imgHTML.rawHTML.trimmingCharacters(in: .whitespaces)
			guard let img = HTMLAttributeParser.extractImage(from: imgTag) else { return nil }
			i += 3
			let link = HTMLAttributeParser.extractAttribute("href", from: tag).flatMap { URL(string: $0) }
			let title = HTMLAttributeParser.extractAttribute("title", from: imgTag)
			return ImageRowItem(source: img.src, alt: img.alt, link: link, width: img.width, height: img.height, title: title)
		}

		return nil
	}

	private mutating func buildParagraph(from children: [Markup]) -> MarkdownBlock {
		var builder = InlineBuilder(theme: theme, fontSize: fontSize, sourceConverter: sourceConverter)
		for child in children { builder.visit(child) }
		let inline = builder.finalize(linkifyURLs: linkifyURLs)
		return .paragraph(content: inline.attributed, links: inline.links, id: nextID())
	}

	mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
		let sourceOffset: Int?
		if let converter = sourceConverter, let range = codeBlock.range {
			sourceOffset = converter.verbatimBlockCodeUTF16Offset(
				lowerLine: range.lowerBound.line, lowerColumn: range.lowerBound.column,
				upperLine: range.upperBound.line, upperColumn: range.upperBound.column,
				rendered: codeBlock.code)
		} else {
			sourceOffset = nil
		}
		blocks.append(.codeBlock(code: codeBlock.code, language: codeBlock.language,
							 sourceOffset: sourceOffset, id: nextID()))
	}

	mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
		var inner = BlockBuilder(theme: theme, fontSize: fontSize, checkboxCounter: checkboxCounter, sourceConverter: sourceConverter)
		inner.linkifyURLs = linkifyURLs
		let children = inner.build(from: blockQuote as Markup)
		blocks.append(.blockquote(children: children, id: nextID()))
	}

	mutating func visitOrderedList(_ list: OrderedList) {
		let items = Array(list.listItems).map { item -> ListItemContent in
			var inner = BlockBuilder(theme: theme, fontSize: fontSize, checkboxCounter: checkboxCounter, sourceConverter: sourceConverter)
			inner.linkifyURLs = linkifyURLs
			let checkbox = item.checkbox.map { $0 == .checked ? CheckboxState.checked : CheckboxState.unchecked }
			let index = checkbox != nil ? checkboxCounter.next() : nil
			return ListItemContent(blocks: inner.build(from: item as Markup), checkbox: checkbox, checkboxIndex: index)
		}
		blocks.append(.orderedList(items: items, start: Int(list.startIndex), id: nextID()))
	}

	mutating func visitUnorderedList(_ list: UnorderedList) {
		let items = Array(list.listItems).map { item -> ListItemContent in
			var inner = BlockBuilder(theme: theme, fontSize: fontSize, checkboxCounter: checkboxCounter, sourceConverter: sourceConverter)
			inner.linkifyURLs = linkifyURLs
			let checkbox = item.checkbox.map { $0 == .checked ? CheckboxState.checked : CheckboxState.unchecked }
			let index = checkbox != nil ? checkboxCounter.next() : nil
			return ListItemContent(blocks: inner.build(from: item as Markup), checkbox: checkbox, checkboxIndex: index)
		}
		blocks.append(.unorderedList(items: items, id: nextID()))
	}

	mutating func visitTable(_ table: Markdown.Table) {
		let headerCells = Array(table.head.cells).map { makeCell($0) }
		var rows: [[TableCell]] = []
		for child in table.body.children {
			guard let row = child as? Markdown.Table.Row else { continue }
			rows.append(Array(row.cells).map { makeCell($0) })
		}
		let alignments = table.columnAlignments.map { Self.convert($0) }
		blocks.append(.table(header: headerCells, rows: rows, columnAlignments: alignments, id: nextID()))
	}

	private static func convert(_ alignment: Markdown.Table.ColumnAlignment?) -> TableColumnAlignment {
		switch alignment {
		case .left: .left
		case .center: .center
		case .right: .right
		case nil: .default
		}
	}

	private func makeCell(_ cell: Markdown.Table.Cell) -> TableCell {
		if let imageCell = imageOnlyTableCell(from: cell) { return imageCell }
		var builder = InlineBuilder(theme: theme, fontSize: fontSize, sourceConverter: sourceConverter)
		return .text(builder.build(from: cell, linkifyURLs: linkifyURLs).attributed,
					 sourceStart: emptyCellSourceStart(cell))
	}

	/// Source offset typing into an EMPTY cell should splice at. The cell's
	/// reported range runs from the first character after the opening pipe
	/// THROUGH the closing pipe, so the insertable columns are
	/// [lower, upper - 2]; land one past the padding space when the cell has
	/// room, so the splice reads `| X |` rather than `|X  |`.
	private func emptyCellSourceStart(_ cell: Markdown.Table.Cell) -> Int? {
		guard cell.childCount == 0, let range = cell.range, let converter = sourceConverter else { return nil }
		let lower = range.lowerBound.column
		let column = max(lower, min(lower + 1, range.upperBound.column - 2))
		return converter.verbatimUTF16Offset(
			lowerLine: range.lowerBound.line, lowerColumn: column,
			upperLine: range.lowerBound.line, upperColumn: column, renderedLength: 0)
	}

	/// If a table cell contains nothing but a single image (HTML <img> or
	/// Markdown image syntax, optionally wrapped in a link), surface it as
	/// an `.image` TableCell so it can render as an actual image instead
	/// of degrading to its alt text.
	private func imageOnlyTableCell(from cell: Markdown.Table.Cell) -> TableCell? {
		// Single Markdown image (![alt](src)) — optionally wrapped in a link
		let firstChild = cell.child(at: 0)
		if cell.childCount == 1, let img = firstChild as? Markdown.Image {
			return .image(source: img.source ?? "", alt: img.plainText, link: nil, width: nil, height: nil)
		}
		if cell.childCount == 1, let link = firstChild as? Markdown.Link,
		   link.childCount == 1, let img = link.child(at: 0) as? Markdown.Image {
			let dest = link.destination.flatMap { URL(string: $0) }
			return .image(source: img.source ?? "", alt: img.plainText, link: dest, width: nil, height: nil)
		}
		// Inline HTML cell — concatenate raw HTML, reject if any non-whitespace
		// text content sits beside the image markup.
		var rawHTML = ""
		for child in cell.children {
			if let html = child as? InlineHTML {
				rawHTML += html.rawHTML
			} else if let text = child as? Markdown.Text {
				if !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
					return nil
				}
			} else {
				return nil
			}
		}
		guard !rawHTML.isEmpty else { return nil }
		if let info = HTMLAttributeParser.extractLinkedImage(from: rawHTML) {
			return .image(source: info.src, alt: info.alt, link: URL(string: info.href), width: info.width, height: info.height)
		}
		if let info = HTMLAttributeParser.extractImage(from: rawHTML) {
			return .image(source: info.src, alt: info.alt, link: nil, width: info.width, height: info.height)
		}
		return nil
	}

	mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
		blocks.append(.thematicBreak(id: nextID()))
	}

	mutating func visitHTMLBlock(_ html: HTMLBlock) {
		blocks.append(.htmlBlock(content: html.rawHTML, id: nextID()))
	}

	private mutating func nextID() -> String {
		counter += 1
		return "block-\(counter)"
	}
}

private extension BlockBuilder {
	mutating func build(from markup: Markup) -> [MarkdownBlock] {
		for child in markup.children { visit(child) }
		return blocks
	}
}
