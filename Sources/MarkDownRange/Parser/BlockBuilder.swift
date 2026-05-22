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
	private var blocks: [MarkdownBlock] = []
	private var counter = 0

	init(theme: MarkdownTheme, fontSize: CGFloat, checkboxCounter: CheckboxCounter = CheckboxCounter()) {
		self.theme = theme
		self.fontSize = fontSize
		self.checkboxCounter = checkboxCounter
	}

	mutating func build(from document: Document, linkifyURLs: Bool = true) -> [MarkdownBlock] {
		self.linkifyURLs = linkifyURLs
		for child in document.children { visit(child) }
		return blocks
	}

	mutating func visitHeading(_ heading: Heading) {
		var builder = InlineBuilder(theme: theme, fontSize: fontSize)
		let inline = builder.build(from: heading, linkifyURLs: linkifyURLs)
		blocks.append(.heading(level: heading.level, content: inline.attributed, id: nextID()))
	}

	mutating func visitParagraph(_ paragraph: Paragraph) {
		let children = Array(paragraph.children)
		let paragraphCarriesOnlyImages = isImageOnly(children)
		var inlineChildren: [Markup] = []
		var pendingImages: [ImageRowItem] = []

		var i = 0
		while i < children.count {
			let child = children[i]
			if let image = child as? Markdown.Image {
				if !inlineChildren.isEmpty {
					blocks.append(buildParagraph(from: inlineChildren))
					inlineChildren = []
				}
				pendingImages.append(imageItem(from: image))
				i += 1
				continue
			}
			if let item = extractInlineHTMLImageItem(from: children, at: &i) {
				if !inlineChildren.isEmpty {
					blocks.append(buildParagraph(from: inlineChildren))
					inlineChildren = []
				}
				pendingImages.append(item)
				continue
			}
			// A run of inline images is "same line" only while the separating
			// content is plain whitespace text. SoftBreaks, LineBreaks, links,
			// emphasis, or anything else terminates the row so authored line
			// boundaries continue to stack visually.
			if !pendingImages.isEmpty, isWhitespaceText(child) {
				i += 1
				continue
			}
			flushPendingImages(&pendingImages, paragraphIsImageOnly: paragraphCarriesOnlyImages,
								imageNode: imageNode(in: paragraph))
			inlineChildren.append(child)
			i += 1
		}

		flushPendingImages(&pendingImages, paragraphIsImageOnly: paragraphCarriesOnlyImages,
							imageNode: imageNode(in: paragraph))
		if !inlineChildren.isEmpty {
			blocks.append(buildParagraph(from: inlineChildren))
		}
	}

	private mutating func flushPendingImages(
		_ images: inout [ImageRowItem],
		paragraphIsImageOnly: Bool,
		imageNode: Markdown.Image?
	) {
		guard !images.isEmpty else { return }
		defer { images.removeAll() }
		if images.count >= 2 {
			blocks.append(.imageRow(images: images, id: nextID()))
			return
		}
		let only = images[0]
		// Promote to a captioned figure only when the paragraph contains
		// nothing but this single image AND the author supplied a markdown
		// title (`![alt](url "caption")`). The title is the explicit opt-in;
		// alt stays for accessibility so existing documents don't grow
		// surprise captions.
		if paragraphIsImageOnly, let caption = imageNode?.title, !caption.isEmpty {
			blocks.append(.figure(image: only, caption: caption, id: nextID()))
			return
		}
		blocks.append(.image(source: only.source, alt: only.alt, width: only.width, height: only.height, id: nextID()))
	}

	private func imageItem(from image: Markdown.Image) -> ImageRowItem {
		ImageRowItem(source: image.source ?? "", alt: image.plainText)
	}

	private func isWhitespaceText(_ markup: Markup) -> Bool {
		guard let text = markup as? Markdown.Text else { return false }
		return text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	private func isImageOnly(_ children: [Markup]) -> Bool {
		var sawImage = false
		for child in children {
			if child is Markdown.Image { sawImage = true; continue }
			if isWhitespaceText(child) { continue }
			// HTML img counts too, but allow only it — anything else (text,
			// emphasis, links, breaks) disqualifies the paragraph from the
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

	private func imageNode(in paragraph: Paragraph) -> Markdown.Image? {
		paragraph.children.compactMap { $0 as? Markdown.Image }.first
	}

	/// Detects `<a href="..."><img src="..."/></a>` or standalone `<img>` in inline HTML nodes.
	private func extractInlineHTMLImageItem(from children: [Markup], at i: inout Int) -> ImageRowItem? {
		guard let html = children[i] as? InlineHTML else { return nil }
		let tag = html.rawHTML.trimmingCharacters(in: .whitespaces)

		// Standalone <img>
		if tag.lowercased().hasPrefix("<img"), let img = HTMLAttributeParser.extractImage(from: tag) {
			i += 1
			return ImageRowItem(source: img.src, alt: img.alt, width: img.width, height: img.height)
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
			return ImageRowItem(source: img.src, alt: img.alt, link: link, width: img.width, height: img.height)
		}

		return nil
	}

	private mutating func buildParagraph(from children: [Markup]) -> MarkdownBlock {
		var builder = InlineBuilder(theme: theme, fontSize: fontSize)
		for child in children { builder.visit(child) }
		let inline = builder.finalize(linkifyURLs: linkifyURLs)
		return .paragraph(content: inline.attributed, links: inline.links, id: nextID())
	}

	mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
		blocks.append(.codeBlock(code: codeBlock.code, language: codeBlock.language, id: nextID()))
	}

	mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
		var inner = BlockBuilder(theme: theme, fontSize: fontSize, checkboxCounter: checkboxCounter)
		inner.linkifyURLs = linkifyURLs
		let children = inner.build(from: blockQuote as Markup)
		blocks.append(.blockquote(children: children, id: nextID()))
	}

	mutating func visitOrderedList(_ list: OrderedList) {
		let items = Array(list.listItems).map { item -> ListItemContent in
			var inner = BlockBuilder(theme: theme, fontSize: fontSize, checkboxCounter: checkboxCounter)
			inner.linkifyURLs = linkifyURLs
			let checkbox = item.checkbox.map { $0 == .checked ? CheckboxState.checked : CheckboxState.unchecked }
			let index = checkbox != nil ? checkboxCounter.next() : nil
			return ListItemContent(blocks: inner.build(from: item as Markup), checkbox: checkbox, checkboxIndex: index)
		}
		blocks.append(.orderedList(items: items, start: Int(list.startIndex), id: nextID()))
	}

	mutating func visitUnorderedList(_ list: UnorderedList) {
		let items = Array(list.listItems).map { item -> ListItemContent in
			var inner = BlockBuilder(theme: theme, fontSize: fontSize, checkboxCounter: checkboxCounter)
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
		var builder = InlineBuilder(theme: theme, fontSize: fontSize)
		return .text(builder.build(from: cell, linkifyURLs: linkifyURLs).attributed)
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
