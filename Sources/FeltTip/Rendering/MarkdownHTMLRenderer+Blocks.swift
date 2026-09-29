//
//  MarkdownHTMLRenderer+Blocks.swift
//  FeltTip
//

import Foundation
import SwiftUI
import MarkdownSyntaxHighlighting

extension MarkdownHTMLRenderer {
	static func renderBlock(_ block: MarkdownBlock) -> String {
		switch block {
		case .heading(let level, let content, _):
			let safeLevel = max(1, min(6, level))
			return "<h\(safeLevel)>\(renderInline(content))</h\(safeLevel)>"

		case .paragraph(let content, _, _):
			return "<p>\(renderInline(content))</p>"

		case .codeBlock(let code, let language, let sourceOffset, _):
			let isMermaid = language?.lowercased() == "mermaid"
			// Export pre-renders mermaid to self-contained diagram markup (inline
			// SVG, or an <img> for DOCX/rich text); emit that instead of the raw
			// source so the diagram shows everywhere.
			if isMermaid, let diagram = prerenderedMermaidDiagrams[code] {
				return "<div class=\"mermaid-diagram\">\(diagram)</div>"
			}
			let classAttr = language.map { " class=\"language-\(escape($0))\"" } ?? ""
			// Syntax-highlight server-side so the webview / QuickLook / export
			// paths get colored code without bundling a JS highlighter. Mermaid
			// keeps its raw source untouched (a diagram engine consumes it).
			var body = isMermaid ? escape(code) : Tokenizer.highlightedHTML(code, escape: { escape($0) })
			if emitSourceOffsets, let sourceOffset {
				if body.isEmpty { body = "<br>" }
				body = "<span data-s=\"\(sourceOffset)\">\(body)</span>"
			}
			return "<pre><code\(classAttr)>\(body)</code></pre>"

		case .blockquote(let children, _):
			var html = "<blockquote>"
			for child in children { html += renderBlock(child) }
			return html + "</blockquote>"

		case .orderedList(let items, let start, _):
			let startAttr = start == 1 ? "" : " start=\"\(start)\""
			return "<ol\(startAttr)>\(renderListItems(items))</ol>"

		case .unorderedList(let items, _):
			return "<ul>\(renderListItems(items))</ul>"

		case .table(let header, let rows, let alignments, _):
			return renderTable(header: header, rows: rows, alignments: alignments)

		case .thematicBreak:
			return "<hr>"

		case .image(let source, let alt, let width, let height, _):
			return renderImage(source: source, alt: alt, width: width, height: height)

		case .imageRow(let images, _):
			var inner = ""
			for item in images {
				inner += renderImage(source: item.source, alt: item.alt, width: item.width, height: item.height, link: item.link)
			}
			return "<div class=\"image-row\">\(inner)</div>"

		case .figure(let item, let caption, _):
			let img = renderImage(source: item.source, alt: item.alt, width: item.width, height: item.height, link: item.link)
			return "<figure>\(img)<figcaption>\(escape(caption))</figcaption></figure>"

		case .htmlBlock(let content, _, _):
			// The one place a document's own markup reaches the page verbatim,
			// and that page hosts the edit bridge — so it must not carry script.
			return HTMLPassthroughSanitizer.sanitize(content)

		case .details(let summary, let isOpen, let children, _):
			var inner = ""
			for child in children { inner += renderBlock(child) }
			let openAttribute = isOpen ? " open" : ""
			return "<details\(openAttribute)><summary>\(escape(summary))</summary>\(inner)</details>"

		case .alert(let type, let children, _):
			var inner = ""
			for child in children { inner += renderBlock(child) }
			return "<div class=\"alert alert-\(type.rawValue)\"><div class=\"alert-label\">\(escape(type.label))</div>\(inner)</div>"

		case .frontmatter(let pairs, _):
			var rows = ""
			for pair in pairs {
				rows += "<tr><th>\(escape(pair.key))</th><td>\(escape(pair.value))</td></tr>"
			}
			return "<table class=\"frontmatter\">\(rows)</table>"

		case .aligned(let alignment, let block, _):
			return "<div style=\"text-align: \(cssAlignment(alignment));\">\(renderBlock(block))</div>"

		case .definitionList(let items, _):
			var body = ""
			for item in items {
				let termHTML = renderInlineMarkdown(
					item.term,
					sourceStart: item.termSourceStart,
					sourceText: item.termSourceText)
				body += "<dt>\(termHTML)</dt>"
				for (index, def) in item.definitions.enumerated() {
					let sourceStart = item.definitionSourceStarts.indices.contains(index)
						? item.definitionSourceStarts[index] : nil
					let sourceText = item.definitionSourceTexts.indices.contains(index)
						? item.definitionSourceTexts[index] : nil
					let definitionHTML = renderInlineMarkdown(
						def, sourceStart: sourceStart, sourceText: sourceText)
					body += "<dd>\(definitionHTML)</dd>"
				}
			}
			return "<dl>\(body)</dl>"
		}
	}

	/// Definition-list preprocessing preserves term/body strings so their
	/// Markdown delimiters survive the block parse. Parse each as a standalone
	/// inline paragraph before emitting the `<dt>`/`<dd>`; escaping the raw
	/// strings made emphasis, code, and links appear literally in the preview.
	static func renderInlineMarkdown(
		_ markdown: String,
		sourceStart: Int?,
		sourceText: String? = nil
	) -> String {
		let shouldTrack = emitSourceOffsets && sourceStart != nil
		let blocks = MarkdownBlockParser.parse(markdown, trackSourceOffsets: shouldTrack)
		guard blocks.count == 1,
			  case .paragraph(let content, _, _) = blocks[0] else {
			return escape(markdown)
		}
		guard let sourceStart, shouldTrack else { return renderInline(content) }
		var shifted = content
		let sourceText = sourceText ?? markdown
		if sourceText == markdown {
			for run in content.runs {
				if let offset = run.markdownSourceOffset {
					shifted[run.range].markdownSourceOffset = sourceStart + offset
				}
			}
			return renderInline(shifted)
		}
		let offsetMap = MarkdownPreprocessor.offsetMap(from: sourceText, to: markdown)
		let source = sourceText as NSString
		let offsets = content.runs.map { run -> (Range<AttributedString.Index>, Int?) in
			guard let offset = run.markdownSourceOffset else { return (run.range, nil) }
			let text = String(content[run.range].characters)
			let length = (text as NSString).length
			guard offset >= 0, offset < offsetMap.count,
			      offset + length <= offsetMap.count else { return (run.range, nil) }
			let mappedStart = offsetMap[offset]
			guard mappedStart + length <= source.length,
			      (0..<length).allSatisfy({ offsetMap[offset + $0] == mappedStart + $0 }),
			      source.substring(with: NSRange(location: mappedStart, length: length)) == text
			else { return (run.range, nil) }
			return (run.range, sourceStart + mappedStart)
		}
		for (range, offset) in offsets {
			shifted[range].markdownSourceOffset = offset
		}
		return renderInline(shifted)
	}

	static func renderListItems(_ items: [ListItemContent]) -> String {
		var result = ""
		for item in items {
			result += item.checkbox == nil ? "<li>" : "<li class=\"task-list-item\">"
			var checkboxHTML = ""
			if let state = item.checkbox {
				let checked = state == .checked ? " checked" : ""
				if emitInteractiveCheckboxes, let index = item.checkboxIndex {
					checkboxHTML = "<input type=\"checkbox\" data-cb=\"\(index)\"\(checked)> "
				} else {
					checkboxHTML = "<input type=\"checkbox\" disabled\(checked)> "
				}
			}
			if item.blocks.isEmpty, emitSourceOffsets, let sourceStart = item.sourceStart {
				result += checkboxHTML + "<span data-s=\"\(sourceStart)\"><br></span>"
				result += "</li>"
				continue
			}
			// Tight-list heuristic — a lone paragraph child renders without
			// its `<p>` wrapper so simple bullet lists don't gain stray
			// vertical whitespace in the exported HTML.
			if item.blocks.count == 1, case .paragraph(let content, _, _) = item.blocks[0] {
				result += checkboxHTML + renderInline(content)
			} else if !checkboxHTML.isEmpty,
			          let first = item.blocks.first,
			          case .paragraph(let content, _, _) = first {
				// A parent task has more than one block because its nested list is
				// a sibling of the leading paragraph. Keep the checkbox inside that
				// paragraph; placing it directly under `<li>` leaves it on a blank
				// line when the paragraph establishes its own block formatting box.
				result += "<p>\(checkboxHTML)\(renderInline(content))</p>"
				for block in item.blocks.dropFirst() {
					result += renderBlock(block)
				}
			} else {
				result += checkboxHTML
				for block in item.blocks {
					result += renderBlock(block)
				}
			}
			result += "</li>"
		}
		return result
	}

	static func renderImage(source: String, alt: String, width: CGFloat?, height: CGFloat?, link: URL? = nil) -> String {
		let src = attributeValue(source, allowedSchemes: imageSchemes)
		var sizeAttr = ""
		if let width { sizeAttr += " width=\"\(Int(width))\"" }
		if let height { sizeAttr += " height=\"\(Int(height))\"" }
		let img = "<img src=\"\(src)\" alt=\"\(attributeValue(alt))\"\(sizeAttr)>"
		if let link {
			return "<a href=\"\(attributeValue(link.absoluteString, allowedSchemes: linkSchemes))\">\(img)</a>"
		}
		return img
	}

	static func renderTable(header: [TableCell], rows: [[TableCell]], alignments: [TableColumnAlignment]) -> String {
		var html = "<table><thead><tr>"
		for (index, cell) in header.enumerated() {
			html += "<th\(styleAttribute(forColumn: index, alignments: alignments))>\(renderCell(cell))</th>"
		}
		html += "</tr></thead>"
		if !rows.isEmpty {
			html += "<tbody>"
			for row in rows {
				html += "<tr>"
				for (index, cell) in row.enumerated() {
					html += "<td\(styleAttribute(forColumn: index, alignments: alignments))>\(renderCell(cell))</td>"
				}
				html += "</tr>"
			}
			html += "</tbody>"
		}
		return html + "</table>"
	}

	private static func styleAttribute(forColumn index: Int, alignments: [TableColumnAlignment]) -> String {
		guard index < alignments.count else { return "" }
		switch alignments[index] {
		case .left, .default: return ""
		case .center: return " style=\"text-align: center;\""
		case .right: return " style=\"text-align: right;\""
		}
	}

	private static func renderCell(_ cell: TableCell) -> String {
		switch cell {
		case .text(let attributed, let sourceStart):
			let inline = renderInline(attributed)
			// An empty cell renders no run, leaving the caret nowhere to map
			// typing from. Give it the same stamped, text-less home that
			// __mdPlaceCaret synthesizes for empty paragraphs.
			if inline.isEmpty, emitSourceOffsets, let sourceStart {
				return "<span data-s=\"\(sourceStart)\"><br></span>"
			}
			return inline
		case .image(let source, let alt, let link, let width, let height):
			return renderImage(source: source, alt: alt, width: width, height: height, link: link)
		}
	}

	static func cssAlignment(_ alignment: HorizontalAlignment) -> String {
		switch alignment {
		case .leading: return "left"
		case .trailing: return "right"
		case .center: return "center"
		default: return "left"
		}
	}
}
