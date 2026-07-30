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

	struct BlockResult: Sendable {
		let fragments: [MarkdownBlockFragment]
		/// JSON string literal for the complete body, built off the main actor.
		let bodyJSON: String
	}

	func bodyFragment(
		markdown: String, theme: MarkdownTheme, fontSize: CGFloat,
		includeSourceOffsets: Bool, interactiveCheckboxes: Bool
	) async -> String {
		MarkdownHTMLRenderer.renderBodyFragment(
			markdown: markdown, theme: theme, fontSize: fontSize,
			includeSourceOffsets: includeSourceOffsets,
			interactiveCheckboxes: interactiveCheckboxes)
	}

	func blockFragments(
		markdown: String, theme: MarkdownTheme, fontSize: CGFloat,
		includeSourceOffsets: Bool, interactiveCheckboxes: Bool
	) async -> [MarkdownBlockFragment] {
		blockResult(
			markdown: markdown, theme: theme, fontSize: fontSize,
			includeSourceOffsets: includeSourceOffsets,
			interactiveCheckboxes: interactiveCheckboxes
		).fragments
	}

	func blockResult(
		markdown: String, theme: MarkdownTheme, fontSize: CGFloat,
		includeSourceOffsets: Bool, interactiveCheckboxes: Bool
	) -> BlockResult {
		let fragments = MarkdownHTMLRenderer.renderBlockFragments(
			markdown: markdown, theme: theme, fontSize: fontSize,
			includeSourceOffsets: includeSourceOffsets,
			interactiveCheckboxes: interactiveCheckboxes)
		let body: String = fragments.map(\.html).joined()
		let encoded = (try? JSONEncoder().encode(body))
			.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
		return BlockResult(fragments: fragments, bodyJSON: encoded)
	}

	/// The full document plus its per-block fragments — the coordinator keeps
	/// the fragments as the baseline for later incremental patches.
	func documentHTML(
		markdown: String, theme: MarkdownTheme, fontSize: CGFloat,
		includeSourceOffsets: Bool, interactiveCheckboxes: Bool,
		embedMermaidEngine: Bool,
		allowRemoteResources: Bool? = nil
	) async -> (html: String, fragments: [MarkdownBlockFragment]) {
		let fragments = MarkdownHTMLRenderer.renderBlockFragments(
			markdown: markdown, theme: theme, fontSize: fontSize,
			includeSourceOffsets: includeSourceOffsets,
			interactiveCheckboxes: interactiveCheckboxes)
		let html = MarkdownHTMLRenderer.wrapDocument(
			body: fragments.lazy.map(\.html).joined(), theme: theme, fontSize: fontSize,
			embedMermaidEngine: embedMermaidEngine, mermaidEngineViaScheme: true,
			contentSecurityPolicy: allowRemoteResources.map {
				MarkdownHTMLRenderer.webViewContentSecurityPolicy(allowRemoteResources: $0)
			})
		return (html, fragments)
	}
}
