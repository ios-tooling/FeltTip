//
//  MarkdownBlockParser.swift
//  MarkdownRendering
//

import Foundation
import Markdown

public enum MarkdownBlockParser {
	/// Per-sub-phase timings for the most recent parse pass, in milliseconds.
	/// Written from the detached background task that runs `parse`; safe to
	/// read on the main actor after that task's `.value` has been awaited
	/// (the await provides the happens-before). Benchmarking only.
	public struct ParseMetrics: Sendable {
		public let preprocessMs: Double
		public let docInitMs: Double
		public let blockBuildMs: Double
		public let postProcessMs: Double
	}
	public nonisolated(unsafe) static var lastParseMetrics: ParseMetrics?

	public static func parse(
		_ content: some MarkdownContent,
		theme: MarkdownTheme = .default,
		fontSize: CGFloat = 16,
		checkboxOffset: Int = 0,
		preprocessed: Bool = false,
		linkifyURLs: Bool = true,
		trackSourceOffsets: Bool = false,
		options: MarkdownOptions = .default
	) -> [MarkdownBlock] {
		let markdown = content.resolveMarkdown()
		let (frontmatter, body, bodyOffset, _) = extractFrontmatter(markdown)
		let tPre0 = CFAbsoluteTimeGetCurrent()
		MarkdownPreprocessor.recordedTimings = [:]
		let processed: String
		let offsetMap: [Int]?
		if preprocessed {
			processed = body
			offsetMap = nil
		} else if trackSourceOffsets {
			// Editable rendering preprocesses too (so highlight, smart quotes,
			// emoji, etc. render), but tracks a processed→source map so edits
			// still resolve to the original source.
			let tracked = MarkdownPreprocessor.processTrackingOffsets(body, options: options)
			processed = tracked.processed
			offsetMap = tracked.map
		} else {
			processed = MarkdownPreprocessor.process(body, options: options)
			offsetMap = nil
		}
		let tDoc0 = CFAbsoluteTimeGetCurrent()
		let document = Document(parsing: processed)
		let tBuild0 = CFAbsoluteTimeGetCurrent()
		let counter = CheckboxCounter(checkboxOffset)
		// Offsets come back through the preprocessing map (when present) and then
		// `bodyOffset` shifts them past any stripped frontmatter, so the stamped
		// offsets address the caller's full source.
		let converter = trackSourceOffsets ? SourceOffsetConverter(processed, baseOffset: bodyOffset, map: offsetMap) : nil
		var builder = BlockBuilder(theme: theme, fontSize: fontSize, checkboxCounter: counter, sourceConverter: converter)
		var blocks = builder.build(from: document, linkifyURLs: linkifyURLs)
		// Frontmatter always renders as the parsed read-only card, including in
		// the styled-text editor. Body blocks carry their own source offsets
		// (shifted past the stripped frontmatter by `bodyOffset`), so keeping the
		// card here doesn't disturb edit mapping for the body.
		if let fm = frontmatter {
			blocks.insert(fm, at: 0)
		}
		let tPost0 = CFAbsoluteTimeGetCurrent()
		let result = postProcess(blocks)
		let tEnd = CFAbsoluteTimeGetCurrent()
		Self.lastParseMetrics = ParseMetrics(
			preprocessMs: (tDoc0 - tPre0) * 1000,
			docInitMs: (tBuild0 - tDoc0) * 1000,
			blockBuildMs: (tPost0 - tBuild0) * 1000,
			postProcessMs: (tEnd - tPost0) * 1000
		)
		return result
	}

	/// Splits any leading YAML frontmatter from the document. Returns the
	/// frontmatter card block, the remaining body, the UTF-16 offset at which
	/// the body begins in the full source (0 when there's no frontmatter), and
	/// the raw frontmatter text (the `---…---` block, nil when absent) for the
	/// editable rendering path.
	private static func extractFrontmatter(_ markdown: String) -> (MarkdownBlock?, String, Int, String?) {
		let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmed.hasPrefix("---") else { return (nil, markdown, 0, nil) }
		let lines = markdown.components(separatedBy: .newlines)
		guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return (nil, markdown, 0, nil) }

		var endIndex: Int?
		for i in 1..<lines.count {
			let line = lines[i].trimmingCharacters(in: .whitespaces)
			if line == "---" || line == "..." {
				endIndex = i; break
			}
		}
		guard let end = endIndex, end > 1 else { return (nil, markdown, 0, nil) }

		// Strict check: every non-blank line in the fenced block must look like
		// a YAML key:value pair (or an indented continuation). Without this,
		// any document that opens with `---` followed by prose is silently
		// devoured as "frontmatter" up to the next `---`.
		var pairs: [(key: String, value: String)] = []
		for i in 1..<end {
			let line = lines[i]
			let stripped = line.trimmingCharacters(in: .whitespaces)
			if stripped.isEmpty { continue }
			if line.first?.isWhitespace == true, !pairs.isEmpty { continue }
			guard let colonIdx = line.firstIndex(of: ":") else { return (nil, markdown, 0, nil) }
			let key = String(line[line.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
			guard isValidFrontmatterKey(key) else { return (nil, markdown, 0, nil) }
			let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
			pairs.append((key, value))
		}
		guard !pairs.isEmpty else { return (nil, markdown, 0, nil) }

		let body = lines[(end + 1)...].joined(separator: "\n")
		// The `---…---` block, without its trailing newline. The body begins one
		// newline after it, so its UTF-16 offset is the block's length + 1.
		let frontText = lines[0...end].joined(separator: "\n")
		let bodyOffset = (frontText as NSString).length + 1
		let block = MarkdownBlock.frontmatter(pairs: pairs, id: "frontmatter")
		return (block, body, bodyOffset, frontText)
	}

	private static func isValidFrontmatterKey(_ key: String) -> Bool {
		guard let first = key.first, first.isLetter else { return false }
		return key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
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
		removeCommentOnlyHTMLBlocks(convertAlerts(groupDetailsBlocks(convertPreBlocks(convertHTMLInlines(convertHTMLHeadings(convertHTMLTables(convertDefinitionLists(blocks))))))))
	}

	/// Drop HTML blocks that contain nothing but HTML comments — they'd
	/// otherwise render as empty 24pt-tall attachments with paragraph spacing
	/// on either side, producing a conspicuous gap around tooling pragmas
	/// like `<!-- prettier-ignore-start -->` that the document author never
	/// meant to be visible.
	private static func removeCommentOnlyHTMLBlocks(_ blocks: [MarkdownBlock]) -> [MarkdownBlock] {
		blocks.filter { block in
			guard case .htmlBlock(let html, _) = block else { return true }
			let stripped = html.replacingOccurrences(
				of: "<!--[\\s\\S]*?-->",
				with: "",
				options: .regularExpression
			).trimmingCharacters(in: .whitespacesAndNewlines)
			return !stripped.isEmpty
		}
	}

	/// Convert standalone `<h1>`…`<h6>` HTML blocks into native heading blocks
	/// so they share font weight/size and outline behavior with markdown
	/// headings. Without this they fell through to the generic HTML block
	/// renderer, which strips heading-level styling and reads as plain text.
	private static func convertHTMLHeadings(_ blocks: [MarkdownBlock]) -> [MarkdownBlock] {
		blocks.map { block in
			guard case .htmlBlock(let html, let id) = block,
				  let parsed = HTMLHeadingParser.parse(html: html, id: id)
			else { return block }
			return parsed
		}
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
			let alignments = parsed.columnAlignments
			return .table(header: parsed.header, rows: parsed.rows, columnAlignments: alignments, id: id)
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
