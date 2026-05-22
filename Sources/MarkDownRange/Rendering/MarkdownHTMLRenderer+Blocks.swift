//
//  MarkdownHTMLRenderer+Blocks.swift
//  MarkDownRange
//

import Foundation
import SwiftUI

extension MarkdownHTMLRenderer {
	static func renderBlock(_ block: MarkdownBlock) -> String {
		switch block {
		case .heading(let level, let content, _):
			let safeLevel = max(1, min(6, level))
			return "<h\(safeLevel)>\(renderInline(content))</h\(safeLevel)>"

		case .paragraph(let content, _, _):
			return "<p>\(renderInline(content))</p>"

		case .codeBlock(let code, let language, _):
			let classAttr = language.map { " class=\"language-\(escape($0))\"" } ?? ""
			return "<pre><code\(classAttr)>\(escape(code))</code></pre>"

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

		case .htmlBlock(let content, _):
			return content

		case .details(let summary, let children, _):
			var inner = ""
			for child in children { inner += renderBlock(child) }
			return "<details><summary>\(escape(summary))</summary>\(inner)</details>"

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
				body += "<dt>\(escape(item.term))</dt>"
				for def in item.definitions {
					body += "<dd>\(escape(def))</dd>"
				}
			}
			return "<dl>\(body)</dl>"
		}
	}

	static func renderListItems(_ items: [ListItemContent]) -> String {
		var result = ""
		for item in items {
			result += "<li>"
			if let state = item.checkbox {
				let checked = state == .checked ? " checked" : ""
				result += "<input type=\"checkbox\" disabled\(checked)> "
			}
			// Tight-list heuristic — a lone paragraph child renders without
			// its `<p>` wrapper so simple bullet lists don't gain stray
			// vertical whitespace in the exported HTML.
			if item.blocks.count == 1, case .paragraph(let content, _, _) = item.blocks[0] {
				result += renderInline(content)
			} else {
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
		case .text(let attributed): return renderInline(attributed)
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
