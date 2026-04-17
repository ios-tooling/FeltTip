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
		// Extract images as separate blocks, text as paragraphs
		var inlineChildren: [Markup] = []
		let children = Array(paragraph.children)

		var i = 0
		while i < children.count {
			if let image = children[i] as? Markdown.Image {
				if !inlineChildren.isEmpty {
					blocks.append(buildParagraph(from: inlineChildren))
					inlineChildren = []
				}
				blocks.append(.image(source: image.source ?? "", alt: image.plainText, id: nextID()))
				i += 1
			} else if let imgBlock = extractInlineHTMLImage(from: children, at: &i) {
				if !inlineChildren.isEmpty {
					blocks.append(buildParagraph(from: inlineChildren))
					inlineChildren = []
				}
				blocks.append(imgBlock)
			} else {
				inlineChildren.append(children[i])
				i += 1
			}
		}

		if !inlineChildren.isEmpty {
			blocks.append(buildParagraph(from: inlineChildren))
		}
	}

	/// Detects `<a href="..."><img src="..."/></a>` or standalone `<img>` in inline HTML nodes.
	private mutating func extractInlineHTMLImage(from children: [Markup], at i: inout Int) -> MarkdownBlock? {
		guard let html = children[i] as? InlineHTML else { return nil }
		let tag = html.rawHTML.trimmingCharacters(in: .whitespaces)

		// Standalone <img>
		if tag.lowercased().hasPrefix("<img"), let img = HTMLAttributeParser.extractImage(from: tag) {
			i += 1
			return .image(source: img.src, alt: img.alt, width: img.width, height: img.height, id: nextID())
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
			return .image(source: img.src, alt: img.alt, width: img.width, height: img.height, id: nextID())
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
		let headerCells = Array(table.head.cells).map { cell -> TableCell in
			var builder = InlineBuilder(theme: theme, fontSize: fontSize)
			return .text(builder.build(from: cell, linkifyURLs: linkifyURLs).attributed)
		}
		var rows: [[TableCell]] = []
		for child in table.body.children {
			guard let row = child as? Markdown.Table.Row else { continue }
			rows.append(Array(row.cells).map { cell in
				var builder = InlineBuilder(theme: theme, fontSize: fontSize)
				return .text(builder.build(from: cell, linkifyURLs: linkifyURLs).attributed)
			})
		}
		blocks.append(.table(header: headerCells, rows: rows, id: nextID()))
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
