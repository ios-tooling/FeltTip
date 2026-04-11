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
		return postProcess(blocks)
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

	private static func postProcess(_ blocks: [MarkdownBlock]) -> [MarkdownBlock] {
		convertAlerts(groupDetailsBlocks(blocks))
	}

	/// Convert blockquotes starting with [!TYPE] into alert blocks
	private static func convertAlerts(_ blocks: [MarkdownBlock]) -> [MarkdownBlock] {
		blocks.map { block in
			guard case .blockquote(let children, let id) = block,
					let firstChild = children.first,
					case .paragraph(let content, let links, let paraID) = firstChild else {
				return block
			}
			let text = String(content.characters)
			guard let alertType = extractAlertType(from: text) else { return block }

			// Strip the [!TYPE] marker and keep remaining text from the first paragraph
			var alertChildren: [MarkdownBlock] = []
			let markerEnd = text.firstIndex(of: "]").map { text.index(after: $0) } ?? text.startIndex
			let afterMarker = String(text[markerEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
			if !afterMarker.isEmpty {
				// Rebuild paragraph without the marker
				var remaining = content
				let charsToDrop = text.count - afterMarker.count
				let dropEnd = remaining.characters.index(remaining.startIndex, offsetBy: charsToDrop)
				remaining.removeSubrange(remaining.startIndex..<dropEnd)
				alertChildren.append(.paragraph(content: remaining, links: links, id: paraID))
			}
			alertChildren.append(contentsOf: Array(children.dropFirst()))
			return .alert(type: alertType, children: convertAlerts(alertChildren), id: id)
		}
	}

	private static func extractAlertType(from text: String) -> AlertType? {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmed.hasPrefix("[!") else { return nil }
		guard let close = trimmed.firstIndex(of: "]") else { return nil }
		let typeStr = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<close])
		return AlertType(from: typeStr)
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
