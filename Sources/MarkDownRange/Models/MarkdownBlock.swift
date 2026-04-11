//
//  MarkdownBlock.swift
//  MarkdownRendering
//

import Foundation

public enum CheckboxState: Sendable {
	case checked, unchecked
}

public struct ListItemContent: Sendable {
	public let blocks: [MarkdownBlock]
	public let checkbox: CheckboxState?

	public init(blocks: [MarkdownBlock], checkbox: CheckboxState? = nil) {
		self.blocks = blocks
		self.checkbox = checkbox
	}
}

public enum MarkdownBlock: Identifiable, Sendable {
	case heading(level: Int, content: AttributedString, id: String)
	case paragraph(content: AttributedString, links: [LinkInfo], id: String)
	case codeBlock(code: String, language: String?, id: String)
	case blockquote(children: [MarkdownBlock], id: String)
	case orderedList(items: [ListItemContent], start: Int, id: String)
	case unorderedList(items: [ListItemContent], id: String)
	case table(header: [AttributedString], rows: [[AttributedString]], id: String)
	case thematicBreak(id: String)
	case image(source: String, alt: String, id: String)
	case htmlBlock(content: String, id: String)
	case details(summary: String, children: [MarkdownBlock], id: String)
	case alert(type: AlertType, children: [MarkdownBlock], id: String)

	public var id: String {
		switch self {
		case .heading(_, _, let id), .paragraph(_, _, let id), .codeBlock(_, _, let id),
			  .blockquote(_, let id), .orderedList(_, _, let id), .unorderedList(_, let id),
			  .table(_, _, let id), .thematicBreak(let id), .image(_, _, let id),
			  .htmlBlock(_, let id), .details(_, _, let id), .alert(_, _, let id):
			return id
		}
	}
}
