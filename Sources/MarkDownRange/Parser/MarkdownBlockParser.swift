//
//  MarkdownBlockParser.swift
//  MarkdownRendering
//

import Foundation
import Markdown

public enum MarkdownBlockParser {
	public static func parse(
		_ content: some MarkdownContent,
		theme: MarkdownTheme = .default,
		fontSize: CGFloat = 16,
		checkboxOffset: Int = 0,
		preprocessed: Bool = false,
		linkifyURLs: Bool = true
	) -> [MarkdownBlock] {
		let markdown = content.resolveMarkdown()
		let (frontmatter, body) = extractFrontmatter(markdown)
		let processed = preprocessed ? body : DefinitionListProcessor.process(HighlightSyntax.process(EmojiShortcodes.process(body)))
		let document = Document(parsing: processed)
		let counter = CheckboxCounter(checkboxOffset)
		var builder = BlockBuilder(theme: theme, fontSize: fontSize, checkboxCounter: counter)
		var blocks = builder.build(from: document, linkifyURLs: linkifyURLs)
		if let fm = frontmatter { blocks.insert(fm, at: 0) }
		return postProcess(blocks)
	}

	private static func extractFrontmatter(_ markdown: String) -> (MarkdownBlock?, String) {
		let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmed.hasPrefix("---") else { return (nil, markdown) }
		let lines = markdown.components(separatedBy: .newlines)
		guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return (nil, markdown) }

		var endIndex: Int?
		for i in 1..<lines.count {
			if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
				endIndex = i; break
			}
		}
		guard let end = endIndex, end > 1 else { return (nil, markdown) }

		var pairs: [(key: String, value: String)] = []
		for i in 1..<end {
			let line = lines[i]
			if let colonIdx = line.firstIndex(of: ":") {
				let key = String(line[line.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
				let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
				if !key.isEmpty { pairs.append((key, value)) }
			}
		}

		let body = lines[(end + 1)...].joined(separator: "\n")
		let block = MarkdownBlock.frontmatter(pairs: pairs, id: "frontmatter")
		return (block, body)
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
		convertAlerts(groupDetailsBlocks(convertPreBlocks(convertHTMLInlines(convertHTMLTables(convertDefinitionLists(blocks))))))
	}

	/// Convert `<dl>` HTML blocks into `.definitionList` blocks.
	private static func convertDefinitionLists(_ blocks: [MarkdownBlock]) -> [MarkdownBlock] {
		blocks.map { block in
			guard case .htmlBlock(let html, let id) = block,
				  html.lowercased().contains("<dl") else { return block }
			let items = parseDefinitionListHTML(html)
			guard !items.isEmpty else { return block }
			return .definitionList(items: items, id: id)
		}
	}

	private static func parseDefinitionListHTML(_ html: String) -> [DefinitionItem] {
		var items: [DefinitionItem] = []
		var currentTerm: String?
		var currentDefs: [String] = []

		for line in html.components(separatedBy: .newlines) {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			let lower = trimmed.lowercased()

			if lower.hasPrefix("<dt>") {
				// Flush previous item
				if let term = currentTerm {
					items.append(DefinitionItem(term: term, definitions: currentDefs))
				}
				currentTerm = stripTag(trimmed, open: "<dt>", close: "</dt>")
				currentDefs = []
			} else if lower.hasPrefix("<dd>") {
				currentDefs.append(stripTag(trimmed, open: "<dd>", close: "</dd>"))
			}
		}
		if let term = currentTerm {
			items.append(DefinitionItem(term: term, definitions: currentDefs))
		}
		return items
	}

	private static func stripTag(_ text: String, open: String, close: String) -> String {
		var result = text
		if let range = result.range(of: open, options: .caseInsensitive) {
			result = String(result[range.upperBound...])
		}
		if let range = result.range(of: close, options: [.caseInsensitive, .backwards]) {
			result = String(result[..<range.lowerBound])
		}
		return result.trimmingCharacters(in: .whitespaces)
	}

	private static func convertHTMLTables(_ blocks: [MarkdownBlock]) -> [MarkdownBlock] {
		blocks.map { block in
			guard case .htmlBlock(let html, let id) = block,
				  html.lowercased().contains("<table"),
				  let parsed = HTMLTableParser.parse(html: html)
			else { return block }
			return .table(header: parsed.header, rows: parsed.rows, id: id)
		}
	}

	private static func convertHTMLInlines(_ blocks: [MarkdownBlock]) -> [MarkdownBlock] {
		blocks.flatMap { block -> [MarkdownBlock] in
			guard case .htmlBlock(let html, let id) = block,
				  let converted = HTMLInlineConverter.convert(html: html, id: id)
			else { return [block] }
			return converted
		}
	}

	/// Convert `<pre>` HTML blocks into code blocks for consistent styling.
	private static func convertPreBlocks(_ blocks: [MarkdownBlock]) -> [MarkdownBlock] {
		blocks.map { block in
			guard case .htmlBlock(let html, let id) = block else { return block }
			let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
			let lower = trimmed.lowercased()
			guard lower.hasPrefix("<pre") else { return block }

			// Extract inner text, stripping <pre>, </pre>, <code>, </code> tags
			var content = trimmed
			// Remove opening <pre...>
			if let closeAngle = content.firstIndex(of: ">") {
				content = String(content[content.index(after: closeAngle)...])
			}
			// Remove closing </pre>
			if let range = content.range(of: "</pre>", options: [.caseInsensitive, .backwards]) {
				content = String(content[..<range.lowerBound])
			}
			// Strip <code...> and </code> if present
			content = content.trimmingCharacters(in: .whitespacesAndNewlines)
			let contentLower = content.lowercased()
			if contentLower.hasPrefix("<code") {
				if let closeAngle = content.firstIndex(of: ">") {
					content = String(content[content.index(after: closeAngle)...])
				}
			}
			if let range = content.range(of: "</code>", options: [.caseInsensitive, .backwards]) {
				content = String(content[..<range.lowerBound])
			}

			// Extract language from <code class="language-xxx">
			var language: String?
			if let codeRange = lower.range(of: "<code"),
			   let classRange = html[codeRange.lowerBound...].range(of: "language-") {
				let afterLang = html[classRange.upperBound...]
				if let end = afterLang.firstIndex(where: { $0 == "\"" || $0 == "'" || $0 == " " || $0 == ">" }) {
					language = String(afterLang[..<end])
				}
			}

			// Decode basic HTML entities
			content = content
				.replacingOccurrences(of: "&lt;", with: "<")
				.replacingOccurrences(of: "&gt;", with: ">")
				.replacingOccurrences(of: "&amp;", with: "&")
				.replacingOccurrences(of: "&quot;", with: "\"")
				.replacingOccurrences(of: "&#39;", with: "'")

			return .codeBlock(code: content, language: language, id: id)
		}
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
