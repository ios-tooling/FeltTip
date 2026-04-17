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

	public init(blocks: [MarkdownBlock], checkbox: CheckboxState? = nil, checkboxIndex: Int? = nil) {
		self.blocks = blocks
		self.checkbox = checkbox
		self.checkboxIndex = checkboxIndex
	}
}

public enum TableCell: Sendable {
	case text(AttributedString)
	case image(source: String, alt: String, link: URL?, width: CGFloat? = nil, height: CGFloat? = nil)

	public init(_ attributed: AttributedString) { self = .text(attributed) }

	public var characters: AttributedString.CharacterView {
		switch self {
		case .text(let str): str.characters
		case .image(_, let alt, _, _, _): AttributedString(alt).characters
		}
	}
}

public struct ImageRowItem: Sendable {
	public let source: String
	public let alt: String
	public let link: URL?
	public let width: CGFloat?
	public let height: CGFloat?

	public init(source: String, alt: String, link: URL? = nil, width: CGFloat? = nil, height: CGFloat? = nil) {
		self.source = source
		self.alt = alt
		self.link = link
		self.width = width
		self.height = height
	}
}

public enum MarkdownBlock: Identifiable, Sendable {
	case heading(level: Int, content: AttributedString, id: String)
	case paragraph(content: AttributedString, links: [LinkInfo], id: String)
	case codeBlock(code: String, language: String?, id: String)
	case blockquote(children: [MarkdownBlock], id: String)
	case orderedList(items: [ListItemContent], start: Int, id: String)
	case unorderedList(items: [ListItemContent], id: String)
	case table(header: [TableCell], rows: [[TableCell]], id: String)
	case thematicBreak(id: String)
	case image(source: String, alt: String, width: CGFloat? = nil, height: CGFloat? = nil, id: String)
	case imageRow(images: [ImageRowItem], id: String)
	case htmlBlock(content: String, id: String)
	case details(summary: String, children: [MarkdownBlock], id: String)
	case alert(type: AlertType, children: [MarkdownBlock], id: String)
	case frontmatter(pairs: [(key: String, value: String)], id: String)
	indirect case aligned(alignment: HorizontalAlignment, block: MarkdownBlock, id: String)

	public var id: String {
		switch self {
		case .heading(_, _, let id), .paragraph(_, _, let id), .codeBlock(_, _, let id),
			  .blockquote(_, let id), .orderedList(_, _, let id), .unorderedList(_, let id),
			  .table(_, _, let id), .thematicBreak(let id), .image(_, _, _, _, let id),
			  .imageRow(_, let id), .htmlBlock(_, let id), .details(_, _, let id),
			  .alert(_, _, let id), .frontmatter(_, let id), .aligned(_, _, let id):
			return id
		}
	}
}
