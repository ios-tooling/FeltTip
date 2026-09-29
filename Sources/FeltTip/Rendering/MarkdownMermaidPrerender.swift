//
//  MarkdownMermaidPrerender.swift
//  FeltTip
//
//  Bridges the parsed document to `MermaidSVGRenderer`: pulls every mermaid
//  source out of the block tree and renders them to inline SVG, producing the
//  `mermaidSVGs` map that `renderDocument` substitutes for raw code blocks.
//

import Foundation

public enum MarkdownMermaidPrerender {
	/// Parses `markdown`, renders its mermaid blocks to inline SVG, and returns a
	/// `source → svg` map suitable for `MarkdownHTMLRenderer.renderDocument(…,
	/// mermaidDiagrams:)`. Use for HTML/PDF export. Empty when there are no
	/// mermaid blocks.
	@MainActor
	public static func svgMap(markdown: String, theme: MarkdownTheme = .default, fontSize: CGFloat = 16) async -> [String: String] {
		let sources = sources(in: markdown, theme: theme, fontSize: fontSize)
		guard !sources.isEmpty else { return [:] }
		return await MermaidSVGRenderer().renderSVGs(for: sources, theme: theme.mermaidTheme)
	}

	/// Maps each mermaid source to a rendered diagram (PNG + size). Use for the
	/// DOCX / rich-text paths, which embed a native text attachment — their
	/// `NSAttributedString` HTML import can't carry inline SVG or `data:` images.
	@MainActor
	public static func imageMap(markdown: String, theme: MarkdownTheme = .default, fontSize: CGFloat = 16) async -> [String: RenderedDiagram] {
		let sources = sources(in: markdown, theme: theme, fontSize: fontSize)
		guard !sources.isEmpty else { return [:] }
		return await MermaidSVGRenderer().renderImages(for: sources, theme: theme.mermaidTheme)
	}

	private static func sources(in markdown: String, theme: MarkdownTheme, fontSize: CGFloat) -> [String] {
		mermaidSources(in: MarkdownBlockParser.parse(markdown, theme: theme, fontSize: fontSize))
	}

	/// Collects every mermaid code-block source in the tree, recursing into the
	/// container blocks that can nest one.
	static func mermaidSources(in blocks: [MarkdownBlock]) -> [String] {
		var sources: [String] = []
		for block in blocks {
			switch block {
			case .codeBlock(let code, let language, _, _):
				if language?.lowercased() == "mermaid" { sources.append(code) }
			case .blockquote(let children, _), .details(_, _, let children, _), .alert(_, let children, _):
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
