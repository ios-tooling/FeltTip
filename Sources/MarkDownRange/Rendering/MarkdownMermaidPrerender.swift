//
//  MarkdownMermaidPrerender.swift
//  MarkDownRange
//
//  Bridges the parsed document to `MermaidSVGRenderer`: pulls every mermaid
//  source out of the block tree and renders them to inline SVG, producing the
//  `mermaidSVGs` map that `renderDocument` substitutes for raw code blocks.
//

import Foundation

public enum MarkdownMermaidPrerender {
	/// Parses `markdown`, renders its mermaid blocks to inline SVG, and returns a
	/// `source → svg` map suitable for `MarkdownHTMLRenderer.renderDocument(…,
	/// mermaidSVGs:)`. Empty when there are no mermaid blocks (or off macOS).
	@MainActor
	public static func svgMap(markdown: String, theme: MarkdownTheme = .default, fontSize: CGFloat = 16) async -> [String: String] {
		#if os(macOS)
		let blocks = MarkdownBlockParser.parse(markdown, theme: theme, fontSize: fontSize)
		let sources = mermaidSources(in: blocks)
		guard !sources.isEmpty else { return [:] }
		return await MermaidSVGRenderer().renderSVGs(for: sources, theme: theme.mermaidTheme)
		#else
		return [:]
		#endif
	}

	/// Collects every mermaid code-block source in the tree, recursing into the
	/// container blocks that can nest one.
	static func mermaidSources(in blocks: [MarkdownBlock]) -> [String] {
		var sources: [String] = []
		for block in blocks {
			switch block {
			case .codeBlock(let code, let language, _):
				if language?.lowercased() == "mermaid" { sources.append(code) }
			case .blockquote(let children, _), .details(_, let children, _), .alert(_, let children, _):
				sources += mermaidSources(in: children)
			case .aligned(_, let child, _):
				sources += mermaidSources(in: [child])
			case .orderedList(let items, _, _), .unorderedList(let items, _):
				for item in items { sources += mermaidSources(in: item.blocks) }
			default:
				break
			}
		}
		return sources
	}
}
