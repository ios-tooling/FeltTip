//
//  MarkdownMetaWalker.swift
//  FeltTip
//

import Foundation

/// Recursively walks parsed `[MarkdownBlock]` and harvests metadata for `MarkdownMeta`.
struct MarkdownMetaWalker {
	var headings: [MarkdownMeta.Heading] = []
	var links: [MarkdownMeta.Link] = []
	var images: [MarkdownMeta.Image] = []
	var codeBlocks: [MarkdownMeta.CodeBlock] = []
	var frontmatter: [MarkdownMeta.FrontmatterPair] = []

	mutating func walk(_ blocks: [MarkdownBlock]) {
		for block in blocks { walk(block) }
	}

	mutating func walk(_ block: MarkdownBlock) {
		switch block {
		case .heading(let level, let content, _):
			headings.append(.init(level: level, text: String(content.characters)))
			collectLinks(in: content)

		case .paragraph(let content, _, _):
			collectLinks(in: content)

		case .codeBlock(let code, let language, _, _):
			let trimmed = code.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
			let lines = trimmed.isEmpty ? 0 : trimmed.components(separatedBy: .newlines).count
			codeBlocks.append(.init(language: language, lineCount: lines))

		case .blockquote(let children, _):
			walk(children)

		case .orderedList(let items, _, _), .unorderedList(let items, _):
			for item in items { walk(item.blocks) }

		case .table(let header, let rows, _, _):
			for cell in header { collectLinks(in: cell) }
			for row in rows { for cell in row { collectLinks(in: cell) } }

		case .image(let source, let alt, _, _, _):
			images.append(.init(source: source, alt: alt))

		case .imageRow(let items, _):
			for item in items { images.append(.init(source: item.source, alt: item.alt)) }

		case .figure(let item, _, _):
			images.append(.init(source: item.source, alt: item.alt))

		case .details(_, _, let children, _), .alert(_, let children, _):
			walk(children)

		case .frontmatter(let pairs, _):
			frontmatter.append(contentsOf: pairs.map { .init(key: $0.key, value: $0.value) })

		case .aligned(_, let inner, _):
			walk(inner)

		case .definitionList(let items, _):
			for item in items {
				let combined = ([item.term] + item.definitions).joined(separator: "\n")
				collectLinks(inPlainText: combined)
			}

		case .htmlBlock(let html, _):
			collectLinks(inPlainText: html)

		case .thematicBreak:
			break
		}
	}

	private mutating func collectLinks(in attributed: AttributedString) {
		for run in attributed.runs {
			guard let url = run.link else { continue }
			let text = String(attributed[run.range].characters)
			links.append(.init(url: url.absoluteString, text: text))
		}
	}

	private mutating func collectLinks(in cell: TableCell) {
		switch cell {
		case .text(let str, _): collectLinks(in: str)
		case .image(let source, let alt, _, _, _):
			images.append(.init(source: source, alt: alt))
		}
	}

	/// Fallback link extraction for raw HTML / definition list text.
	private mutating func collectLinks(inPlainText text: String) {
		let pattern = #/\[([^\]]+)\]\(([^)\s]+)\)/#
		for match in text.matches(of: pattern) {
			links.append(.init(url: String(match.2), text: String(match.1)))
		}
	}
}
