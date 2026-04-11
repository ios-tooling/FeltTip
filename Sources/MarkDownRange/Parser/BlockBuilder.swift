//
//  BlockBuilder.swift
//  MarkdownRendering
//

import Foundation
import Markdown
import SwiftUI

struct BlockBuilder: MarkupWalker {
	let theme: MarkdownTheme
	let fontSize: CGFloat
	private var blocks: [MarkdownBlock] = []
	private var counter = 0

	init(theme: MarkdownTheme, fontSize: CGFloat) {
		self.theme = theme
		self.fontSize = fontSize
	}

	mutating func build(from document: Document) -> [MarkdownBlock] {
		for child in document.children { visit(child) }
		return blocks
	}

	mutating func visitHeading(_ heading: Heading) {
		var builder = InlineBuilder(theme: theme, fontSize: fontSize)
		let inline = builder.build(from: heading)
		blocks.append(.heading(level: heading.level, content: inline.attributed, id: nextID()))
	}

	mutating func visitParagraph(_ paragraph: Paragraph) {
		// Extract images as separate blocks, text as paragraphs
		var inlineChildren: [Markup] = []

		for child in paragraph.children {
			if let image = child as? Markdown.Image {
				// Flush pending inline content first
				if !inlineChildren.isEmpty {
					let para = buildParagraph(from: inlineChildren)
					blocks.append(para)
					inlineChildren = []
				}
				blocks.append(.image(source: image.source ?? "", alt: image.plainText, id: nextID()))
			} else {
				inlineChildren.append(child)
			}
		}

		if !inlineChildren.isEmpty {
			blocks.append(buildParagraph(from: inlineChildren))
		}
	}

	private mutating func buildParagraph(from children: [Markup]) -> MarkdownBlock {
		var builder = InlineBuilder(theme: theme, fontSize: fontSize)
		for child in children { builder.visit(child) }
		let inline = builder.finalize()
		return .paragraph(content: inline.attributed, links: inline.links, id: nextID())
	}

	mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
		blocks.append(.codeBlock(code: codeBlock.code, language: codeBlock.language, id: nextID()))
	}

	mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
		var inner = BlockBuilder(theme: theme, fontSize: fontSize)
		let children = inner.build(from: blockQuote)
		blocks.append(.blockquote(children: children, id: nextID()))
	}

	mutating func visitOrderedList(_ list: OrderedList) {
		let items = Array(list.listItems).map { item -> ListItemContent in
			var inner = BlockBuilder(theme: theme, fontSize: fontSize)
			let checkbox = item.checkbox.map { $0 == .checked ? CheckboxState.checked : CheckboxState.unchecked }
			return ListItemContent(blocks: inner.build(from: item), checkbox: checkbox)
		}
		blocks.append(.orderedList(items: items, start: Int(list.startIndex), id: nextID()))
	}

	mutating func visitUnorderedList(_ list: UnorderedList) {
		let items = Array(list.listItems).map { item -> ListItemContent in
			var inner = BlockBuilder(theme: theme, fontSize: fontSize)
			let checkbox = item.checkbox.map { $0 == .checked ? CheckboxState.checked : CheckboxState.unchecked }
			return ListItemContent(blocks: inner.build(from: item), checkbox: checkbox)
		}
		blocks.append(.unorderedList(items: items, id: nextID()))
	}

	mutating func visitTable(_ table: Markdown.Table) {
		let headerCells = Array(table.head.cells).map { cell -> AttributedString in
			var builder = InlineBuilder(theme: theme, fontSize: fontSize)
			return builder.build(from: cell).attributed
		}
		var rows: [[AttributedString]] = []
		for child in table.body.children {
			guard let row = child as? Markdown.Table.Row else { continue }
			rows.append(Array(row.cells).map { cell in
				var builder = InlineBuilder(theme: theme, fontSize: fontSize)
				return builder.build(from: cell).attributed
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
	mutating func build(from markup: some Markup) -> [MarkdownBlock] {
		for child in markup.children { visit(child) }
		return blocks
	}
}
