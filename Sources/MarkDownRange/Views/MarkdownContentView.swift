//
//  MarkdownContentView.swift
//  MarkdownRendering
//

import SwiftUI

public struct MarkdownContentView: View {
	private let blocks: [MarkdownBlock]
	private let theme: MarkdownTheme
	private let fontSize: CGFloat
	private let baseURL: URL?
	private let onLinkHover: ((String?) -> Void)?

	public init(
		content: some MarkdownContent,
		theme: MarkdownTheme = .default,
		fontSize: CGFloat = 16,
		baseURL: URL? = nil,
		onLinkHover: ((String?) -> Void)? = nil,
		linkifyURLs: Bool = true
	) {
		self.blocks = MarkdownBlockParser.parse(content, theme: theme, fontSize: fontSize, linkifyURLs: linkifyURLs)
		self.theme = theme
		self.fontSize = fontSize
		self.baseURL = baseURL
		self.onLinkHover = onLinkHover
	}

	public init(
		blocks: [MarkdownBlock],
		theme: MarkdownTheme,
		fontSize: CGFloat,
		baseURL: URL?,
		onLinkHover: ((String?) -> Void)?
	) {
		self.blocks = blocks
		self.theme = theme
		self.fontSize = fontSize
		self.baseURL = baseURL
		self.onLinkHover = onLinkHover
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			ForEach(blocks) { block in
				blockView(for: block)
			}
		}
	}

	@ViewBuilder private func blockView(for block: MarkdownBlock) -> some View {
		Self.blockView(for: block, theme: theme, fontSize: fontSize, baseURL: baseURL, onLinkHover: onLinkHover)
	}

	@ViewBuilder static func blockView(
		for block: MarkdownBlock,
		theme: MarkdownTheme,
		fontSize: CGFloat,
		baseURL: URL?,
		onLinkHover: ((String?) -> Void)?
	) -> some View {
		switch block {
		case .heading(let level, let content, _):
			HeadingBlockView(level: level, content: content, theme: theme, fontSize: fontSize)
		case .paragraph(let content, let links, _):
			ParagraphBlockView(content: content, links: links, onLinkHover: onLinkHover)
		case .codeBlock(let code, let language, _):
			if language?.lowercased() == "mermaid" {
				#if os(macOS)
				MermaidBlockView(code: code, theme: theme)
				#else
				CodeBlockView(code: code, language: language, theme: theme)
				#endif
			} else {
				CodeBlockView(code: code, language: language, theme: theme)
			}
		case .blockquote(let children, _):
			BlockQuoteView(children: children, theme: theme, fontSize: fontSize, baseURL: baseURL, onLinkHover: onLinkHover)
		case .orderedList(let items, let start, _):
			ListBlockView(items: items, ordered: true, start: start, theme: theme, fontSize: fontSize, baseURL: baseURL, onLinkHover: onLinkHover)
		case .unorderedList(let items, _):
			ListBlockView(items: items, ordered: false, start: 1, theme: theme, fontSize: fontSize, baseURL: baseURL, onLinkHover: onLinkHover)
		case .table(let header, let rows, let columnAlignments, _):
			TableBlockView(header: header, rows: rows, columnAlignments: columnAlignments, theme: theme, fontSize: fontSize)
		case .thematicBreak:
			ThematicBreakView()
		case .image(let source, let alt, let width, let height, _):
			ImageBlockView(source: source, alt: alt, theme: theme, baseURL: baseURL, htmlWidth: width, htmlHeight: height)
		case .imageRow(let images, _):
			ImageRowView(images: images, theme: theme, baseURL: baseURL, onLinkHover: onLinkHover)
		case .htmlBlock(let content, _):
			HTMLBlockView(html: content, theme: theme, fontSize: fontSize)
		case .details(let summary, let children, _):
			DetailsBlockView(summary: summary, children: children, theme: theme, fontSize: fontSize, baseURL: baseURL, onLinkHover: onLinkHover)
		case .alert(let type, let children, _):
			AlertBlockView(type: type, children: children, theme: theme, fontSize: fontSize, baseURL: baseURL, onLinkHover: onLinkHover)
		case .frontmatter(let pairs, _):
			FrontmatterView(pairs: pairs, theme: theme)
		case .aligned(let alignment, let inner, _):
			// Headings need the alignment pushed into their own layout — the
			// inner VStack(alignment: .leading) + Divider otherwise hug the
			// leading edge regardless of any outer .frame alignment.
			if case .heading(let level, let content, _) = inner {
				AnyView(
					HeadingBlockView(
						level: level,
						content: content,
						theme: theme,
						fontSize: fontSize,
						alignment: alignment
					)
				)
			} else {
				AnyView(
					Self.blockView(for: inner, theme: theme, fontSize: fontSize, baseURL: baseURL, onLinkHover: onLinkHover)
						.frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
				)
			}
		case .definitionList(let items, _):
			DefinitionListView(items: items, theme: theme, fontSize: fontSize)
		}
	}
}
