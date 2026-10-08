//
//  MarkdownBlock.swift
//  MarkdownRendering
//

import Foundation
import SwiftUI

public enum CheckboxState: Sendable {
	case checked, unchecked
}

public struct ListItemContent: Sendable {
	public let blocks: [MarkdownBlock]
	public let checkbox: CheckboxState?
	public let checkboxIndex: Int?
	/// Source insertion point for an item with no visible content. The editable
	/// renderer uses this to keep template placeholders such as `- ` focusable.
	public let sourceStart: Int?

	public init(
		blocks: [MarkdownBlock], checkbox: CheckboxState? = nil,
		checkboxIndex: Int? = nil, sourceStart: Int? = nil
	) {
		self.blocks = blocks
		self.checkbox = checkbox
		self.checkboxIndex = checkboxIndex
		self.sourceStart = sourceStart
	}
}

public enum TableCell: Sendable {
	/// `sourceStart` is the offset typing into an EMPTY cell should splice
	/// at (inside the pipes, past the padding). The editable renderer emits
	/// it as the cell's caret home; non-empty cells derive positions from
	/// their stamped runs instead and leave it nil.
	case text(InlineContent, sourceStart: Int? = nil)
	case image(source: String, alt: String, link: URL?, width: CGFloat? = nil, height: CGFloat? = nil)

	public init(_ content: InlineContent) { self = .text(content) }

	/// The cell's plain text.
	public var characters: String {
		switch self {
		case .text(let content, _): content.characters
		case .image(_, let alt, _, _, _): alt
		}
	}
}

public struct ImageRowItem: Sendable {
	public let source: String
	public let alt: String
	public let link: URL?
	public let width: CGFloat?
	public let height: CGFloat?
	/// Author-supplied caption text, from the markdown title syntax
	/// (`![alt](url "title")`) or an HTML `<img title="…">`. Used by the
	/// block builder to promote a standalone image to a `.figure`. `nil`
	/// means no caption is available — the image renders without one.
	public let title: String?

	public init(source: String, alt: String, link: URL? = nil, width: CGFloat? = nil, height: CGFloat? = nil, title: String? = nil) {
		self.source = source
		self.alt = alt
		self.link = link
		self.width = width
		self.height = height
		self.title = title
	}
}

public enum MarkdownBlock: Identifiable, Sendable {
	case heading(level: Int, content: InlineContent, id: String)
	case paragraph(content: InlineContent, links: [LinkInfo], id: String)
	case codeBlock(code: String, language: String?, sourceOffset: Int? = nil, id: String)
	case blockquote(children: [MarkdownBlock], id: String)
	case orderedList(items: [ListItemContent], start: Int, id: String)
	case unorderedList(items: [ListItemContent], id: String)
	case table(header: [TableCell], rows: [[TableCell]], columnAlignments: [TableColumnAlignment], id: String)
	case thematicBreak(id: String)
	case image(source: String, alt: String, width: CGFloat? = nil, height: CGFloat? = nil, id: String)
	case imageRow(images: [ImageRowItem], id: String)
	case figure(image: ImageRowItem, caption: String, id: String)
	case htmlBlock(content: String, sourceOffset: Int?, id: String)
	case details(summary: String, isOpen: Bool = false, children: [MarkdownBlock], id: String)
	case alert(type: AlertType, children: [MarkdownBlock], id: String)
	case frontmatter(pairs: [(key: String, value: String)], id: String)
	indirect case aligned(alignment: HorizontalAlignment, block: MarkdownBlock, id: String)
	case definitionList(items: [DefinitionItem], id: String)

	public var id: String {
		switch self {
		case .heading(_, _, let id), .paragraph(_, _, let id), .codeBlock(_, _, _, let id),
			  .blockquote(_, let id), .orderedList(_, _, let id), .unorderedList(_, let id),
			  .table(_, _, _, let id), .thematicBreak(let id), .image(_, _, _, _, let id),
			  .imageRow(_, let id), .figure(_, _, let id), .htmlBlock(_, _, let id),
			  .details(_, _, _, let id), .alert(_, _, let id), .frontmatter(_, let id),
			  .aligned(_, _, let id), .definitionList(_, let id):
			return id
		}
	}
}
