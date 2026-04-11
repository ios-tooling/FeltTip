//
//  MarkdownBlockParser.swift
//  MarkdownRendering
//

import Foundation
import Markdown

public enum MarkdownBlockParser {
	public static func parse(
		_ markdown: String,
		theme: MarkdownTheme = .default,
		fontSize: CGFloat = 16
	) -> [MarkdownBlock] {
		let document = Document(parsing: markdown)
		var builder = BlockBuilder(theme: theme, fontSize: fontSize)
		let blocks = builder.build(from: document)
		return groupDetailsBlocks(blocks)
	}

	/// Groups consecutive blocks between <details> and </details> HTML blocks
	/// into a single .details block with parsed summary and children.
	private static func groupDetailsBlocks(_ blocks: [MarkdownBlock]) -> [MarkdownBlock] {
		var result: [MarkdownBlock] = []
		var i = 0

		while i < blocks.count {
			guard case .htmlBlock(let html, let id) = blocks[i],
					html.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("<details") else {
				result.append(blocks[i])
				i += 1
				continue
			}

			// Found <details> opening — extract summary from this HTML block
			let summary = extractSummary(from: html)
			var children: [MarkdownBlock] = []
			i += 1

			// Collect blocks until we find </details>
			while i < blocks.count {
				if case .htmlBlock(let closeHTML, _) = blocks[i],
					closeHTML.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().contains("</details>") {
					i += 1
					break
				}
				children.append(blocks[i])
				i += 1
			}

			result.append(.details(summary: summary, children: groupDetailsBlocks(children), id: id))
		}
		return result
	}

	private static func extractSummary(from html: String) -> String {
		let lower = html.lowercased()
		guard let start = lower.range(of: "<summary>"),
				let end = lower.range(of: "</summary>") else { return "Details" }

		let summaryStart = html.index(start.upperBound, offsetBy: 0)
		let summaryEnd = html.index(end.lowerBound, offsetBy: 0)
		guard summaryStart < summaryEnd else { return "Details" }

		return String(html[summaryStart..<summaryEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
	}
}
