//
//  MarkdownContent.swift
//  FeltTip
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
		resolveMarkdown(timeout: .seconds(10))
	}

	func resolveMarkdown(
		timeout: Duration,
		reader: @escaping @Sendable (URL) throws -> String = {
			try String(contentsOf: $0, encoding: .utf8)
		}
	) -> String {
		(try? BoundedSynchronousWork.runSynchronously(timeout: timeout) {
			try reader(self)
		}) ?? ""
	}
}
