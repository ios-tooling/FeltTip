//
//  MarkdownBlockContentHash.swift
//  FeltTip
//
//  A block's rendered HTML is a pure function of its content plus the render
//  flags, never of its positional `id`. Hashing that content lets a re-render
//  reuse the previous fragment for every block that did not change instead of
//  regenerating its HTML, which was the largest cost left in a keystroke
//  re-render after parsing. Every payload field that reaches the HTML is
//  folded in — including positional data such as checkbox indices and
//  source stamps, so an insertion that shifts them invalidates the reuse.
//

import Foundation
import SwiftUI

extension MarkdownBlock {
	/// Hash of everything that determines this block's HTML, excluding `id`.
	/// `flags` distinguishes render modes whose HTML differs for the same block.
	func contentHash(flags: Int) -> Int {
		var hasher = Hasher()
		hasher.combine(flags)
		hashContent(into: &hasher)
		return hasher.finalize()
	}

	func hashContent(into hasher: inout Hasher) {
		switch self {
		case .heading(let level, let content, _):
			hasher.combine(0); hasher.combine(level); Self.hash(content, into: &hasher)
		case .paragraph(let content, let links, _):
			hasher.combine(1); Self.hash(content, into: &hasher)
			hasher.combine(links.count)
			for link in links { hasher.combine(link.url); hasher.combine(link.characterOffset) }
		case .codeBlock(let code, let language, let sourceOffset, _):
			hasher.combine(2); hasher.combine(code); hasher.combine(language); hasher.combine(sourceOffset)
		case .blockquote(let children, _):
			hasher.combine(3); Self.hash(children, into: &hasher)
		case .orderedList(let items, let start, _):
			hasher.combine(4); hasher.combine(start); Self.hash(items, into: &hasher)
		case .unorderedList(let items, _):
			hasher.combine(5); Self.hash(items, into: &hasher)
		case .table(let header, let rows, let alignments, _):
			hasher.combine(6)
			Self.hash(header, into: &hasher)
			hasher.combine(rows.count)
			for row in rows { Self.hash(row, into: &hasher) }
			hasher.combine(alignments.count)
			for alignment in alignments { hasher.combine(String(describing: alignment)) }
		case .thematicBreak:
			hasher.combine(7)
		case .image(let source, let alt, let width, let height, _):
			hasher.combine(8); hasher.combine(source); hasher.combine(alt)
			hasher.combine(width); hasher.combine(height)
		case .imageRow(let images, _):
			hasher.combine(9); hasher.combine(images.count)
			for image in images { Self.hash(image, into: &hasher) }
		case .figure(let image, let caption, _):
			hasher.combine(10); Self.hash(image, into: &hasher); hasher.combine(caption)
		case .htmlBlock(let content, let sourceOffset, _):
			hasher.combine(11); hasher.combine(content); hasher.combine(sourceOffset)
		case .details(let summary, let isOpen, let children, _):
			hasher.combine(12); hasher.combine(summary); hasher.combine(isOpen)
			Self.hash(children, into: &hasher)
		case .alert(let type, let children, _):
			hasher.combine(13); hasher.combine(type.rawValue); Self.hash(children, into: &hasher)
		case .frontmatter(let pairs, _):
			hasher.combine(14); hasher.combine(pairs.count)
			for pair in pairs { hasher.combine(pair.key); hasher.combine(pair.value) }
		case .aligned(let alignment, let block, _):
			hasher.combine(15); hasher.combine(String(describing: alignment))
			block.hashContent(into: &hasher)
		case .definitionList(let items, _):
			hasher.combine(16); hasher.combine(items.count)
			for item in items {
				hasher.combine(item.term); hasher.combine(item.definitions)
				hasher.combine(item.termSourceStart); hasher.combine(item.definitionSourceStarts)
				hasher.combine(item.termSourceText); hasher.combine(item.definitionSourceTexts)
				hasher.combine(item.linkReferenceDefinitions)
			}
		}
	}

	/// `AttributedString`'s own `hash(into:)` walks Characters and cost more
	/// than rendering the HTML it was meant to save. Hash each run's text as
	/// UTF-8 bytes plus its attribute container instead; runs are canonical,
	/// so equal strings hash equally.
	static func hash(_ attributed: AttributedString, into hasher: inout Hasher) {
		for run in attributed.runs {
			var text = String(attributed[run.range].characters)
			text.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
			hasher.combine(run.attributes)
		}
	}

	private static func hash(_ blocks: [MarkdownBlock], into hasher: inout Hasher) {
		hasher.combine(blocks.count)
		for block in blocks { block.hashContent(into: &hasher) }
	}

	private static func hash(_ items: [ListItemContent], into hasher: inout Hasher) {
		hasher.combine(items.count)
		for item in items {
			hash(item.blocks, into: &hasher)
			hasher.combine(item.checkbox.map { $0 == .checked ? 1 : 2 } ?? 0)
			hasher.combine(item.checkboxIndex)
			hasher.combine(item.sourceStart)
		}
	}

	private static func hash(_ cells: [TableCell], into hasher: inout Hasher) {
		hasher.combine(cells.count)
		for cell in cells {
			switch cell {
			case .text(let attributed, let sourceStart):
				hasher.combine(0); Self.hash(attributed, into: &hasher); hasher.combine(sourceStart)
			case .image(let source, let alt, let link, let width, let height):
				hasher.combine(1); hasher.combine(source); hasher.combine(alt)
				hasher.combine(link); hasher.combine(width); hasher.combine(height)
			}
		}
	}

	private static func hash(_ image: ImageRowItem, into hasher: inout Hasher) {
		hasher.combine(image.source); hasher.combine(image.alt); hasher.combine(image.link)
		hasher.combine(image.width); hasher.combine(image.height); hasher.combine(image.title)
	}
}
