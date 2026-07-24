//
//  MarkdownRenderService.swift
//  MarkDownRange
//
//  Serializes markdown → HTML rendering off the main actor. The full-document
//  parse + HTML build for a large file runs to hundreds of milliseconds —
//  running it on the main thread froze typing and scrolling on every
//  structural edit and split-pane preview refresh. Callers await a render
//  here and drop the result if a newer render superseded it (the coordinator
//  keeps the generation counter; the actor just does the work in order).
//

import Foundation

actor MarkdownRenderService {
	static let shared = MarkdownRenderService()

	func bodyFragment(
		markdown: String, theme: MarkdownTheme, fontSize: CGFloat,
		includeSourceOffsets: Bool, interactiveCheckboxes: Bool
	) -> String {
		MarkdownHTMLRenderer.renderBodyFragment(
			markdown: markdown, theme: theme, fontSize: fontSize,
			includeSourceOffsets: includeSourceOffsets,
			interactiveCheckboxes: interactiveCheckboxes)
	}

	func documentHTML(
		markdown: String, theme: MarkdownTheme, fontSize: CGFloat,
		includeSourceOffsets: Bool, interactiveCheckboxes: Bool,
		embedMermaidEngine: Bool
	) -> String {
		MarkdownHTMLRenderer.renderDocument(
			markdown: markdown, theme: theme, fontSize: fontSize,
			includeSourceOffsets: includeSourceOffsets,
			interactiveCheckboxes: interactiveCheckboxes,
			embedMermaidEngine: embedMermaidEngine,
			mermaidEngineViaScheme: true)
	}
}
