//
//  MarkdownBlockContentHash.swift
//  FeltTip
//
//  A block's rendered HTML is a pure function of its content plus the render
//  flags, never of its positional `id`. Hashing that content lets a re-render
//  reuse the previous fragment for every block that did not change instead of
//  regenerating its HTML, which was the largest cost left in a keystroke
//  re-render after parsing.
//
//  Source stamps are hashed relative to the block's first stamp. An edit
//  shifts every stamp after it by the same amount, so a block whose text did
//  not change still hashes equal; the fragment remembers the absolute base it
//  was rendered at, and the reuse shifts the cached HTML's stamps by the
//  difference. Anything else positional that reaches the HTML — checkbox
//  indices above all — is hashed as is, so an edit that changes it misses.
//

import Foundation
import SwiftUI

/// The content hash of a block plus the absolute stamp its offsets were
/// hashed relative to (nil for a block with no stamps).
struct MarkdownBlockContentHash: Hashable, Sendable {
	let value: Int
	let stampBase: Int?
}

extension MarkdownBlock {
	/// `flags` distinguishes render modes whose HTML differs for the same block.
	func contentHash(flags: Int) -> MarkdownBlockContentHash {
		var hasher = StampRelativeHasher()
		hasher.combine(flags)
		hashContent(into: &hasher)
		return MarkdownBlockContentHash(value: hasher.finalize(), stampBase: hasher.base)
	}

	func hashContent(into hasher: inout StampRelativeHasher) {
		switch self {
		case .heading(let level, let content, _):
			hasher.combine(0); hasher.combine(level); hasher.combine(content)
		case .paragraph(let content, let links, _):
			hasher.combine(1); hasher.combine(content)
			hasher.combine(links.count)
			for link in links { hasher.combine(link.url); hasher.combine(link.characterOffset) }
		case .codeBlock(let code, let language, let sourceOffset, _):
			hasher.combine(2); hasher.combine(code); hasher.combine(language)
			hasher.combineOffset(sourceOffset)
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
			hasher.combine(11); hasher.combine(content); hasher.combineOffset(sourceOffset)
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
				hasher.combineOffset(item.termSourceStart)
				hasher.combine(item.definitionSourceStarts.count)
				for start in item.definitionSourceStarts { hasher.combineOffset(start) }
				hasher.combine(item.termSourceText); hasher.combine(item.definitionSourceTexts)
				hasher.combine(item.linkReferenceDefinitions)
			}
		}
	}

	private static func hash(_ blocks: [MarkdownBlock], into hasher: inout StampRelativeHasher) {
		hasher.combine(blocks.count)
		for block in blocks { block.hashContent(into: &hasher) }
	}

	private static func hash(_ items: [ListItemContent], into hasher: inout StampRelativeHasher) {
		hasher.combine(items.count)
		for item in items {
			hash(item.blocks, into: &hasher)
			hasher.combine(item.checkbox.map { $0 == .checked ? 1 : 2 } ?? 0)
			hasher.combine(item.checkboxIndex)
			hasher.combineOffset(item.sourceStart)
		}
	}

	private static func hash(_ cells: [TableCell], into hasher: inout StampRelativeHasher) {
		hasher.combine(cells.count)
		for cell in cells {
			switch cell {
			case .text(let attributed, let sourceStart):
				hasher.combine(0); hasher.combine(attributed); hasher.combineOffset(sourceStart)
			case .image(let source, let alt, let link, let width, let height):
				hasher.combine(1); hasher.combine(source); hasher.combine(alt)
				hasher.combine(link); hasher.combine(width); hasher.combine(height)
			}
		}
	}

	private static func hash(_ image: ImageRowItem, into hasher: inout StampRelativeHasher) {
		hasher.combine(image.source); hasher.combine(image.alt); hasher.combine(image.link)
		hasher.combine(image.width); hasher.combine(image.height); hasher.combine(image.title)
	}
}

/// A `Hasher` that folds source offsets in relative to the first one it sees.
struct StampRelativeHasher {
	private var hasher = Hasher()
	/// The first absolute offset combined, which every later offset is
	/// hashed relative to.
	private(set) var base: Int?

	mutating func combine<Value: Hashable>(_ value: Value) {
		hasher.combine(value)
	}

	mutating func combineOffset(_ offset: Int?) {
		guard let offset else { hasher.combine(Int?.none); return }
		if base == nil { base = offset }
		hasher.combine(offset - base!)
	}

	/// Hash each run's text as UTF-8 bytes plus its formatting, with the two
	/// source offsets folded in relative to the base so a shifted block still
	/// hashes equally.
	mutating func combine(_ content: InlineContent) {
		for run in content.runs {
			var text = run.text
			text.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
			hasher.combine(run.style.rawValue)
			hasher.combine(run.link)
			hasher.combine(run.toolTip)
			combineOffset(run.markdownSourceOffset)
			combineOffset(run.markdownEscapedPipeSourceOffset)
		}
	}

	func finalize() -> Int { hasher.finalize() }
}
