//
//  MarkdownContent.swift
//  MarkDownRange
//

import Foundation

/// A source of markdown text. Allows views and parsers to accept String, URL, or Data
/// interchangeably. Conformers return the raw markdown string via `resolveMarkdown()`.
public protocol MarkdownContent {
	func resolveMarkdown() -> String
}

extension String: MarkdownContent {
	public func resolveMarkdown() -> String { self }
}

extension Data: MarkdownContent {
	public func resolveMarkdown() -> String {
		String(data: self, encoding: .utf8) ?? ""
	}
}

extension URL: MarkdownContent {
	public func resolveMarkdown() -> String {
		(try? String(contentsOf: self, encoding: .utf8)) ?? ""
	}
}
