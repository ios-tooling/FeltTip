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
	) async -> String {
		let worker = Task.detached {
			MarkdownHTMLRenderer.renderBodyFragment(
				markdown: markdown, theme: theme, fontSize: fontSize,
				includeSourceOffsets: includeSourceOffsets,
				interactiveCheckboxes: interactiveCheckboxes)
		}
		return await withTaskCancellationHandler(
			operation: { await worker.value },
			onCancel: { worker.cancel() })
	}

	func blockFragments(
		markdown: String, theme: MarkdownTheme, fontSize: CGFloat,
		includeSourceOffsets: Bool, interactiveCheckboxes: Bool
	) async -> [MarkdownBlockFragment] {
		let worker = Task.detached {
			MarkdownHTMLRenderer.renderBlockFragments(
				markdown: markdown, theme: theme, fontSize: fontSize,
				includeSourceOffsets: includeSourceOffsets,
				interactiveCheckboxes: interactiveCheckboxes)
		}
		return await withTaskCancellationHandler(
			operation: { await worker.value },
			onCancel: { worker.cancel() })
	}

	/// The full document plus its per-block fragments — the coordinator keeps
	/// the fragments as the baseline for later incremental patches.
	func documentHTML(
		markdown: String, theme: MarkdownTheme, fontSize: CGFloat,
		includeSourceOffsets: Bool, interactiveCheckboxes: Bool,
		embedMermaidEngine: Bool
	) async -> (html: String, fragments: [MarkdownBlockFragment]) {
		let worker = Task.detached {
			let fragments = MarkdownHTMLRenderer.renderBlockFragments(
				markdown: markdown, theme: theme, fontSize: fontSize,
				includeSourceOffsets: includeSourceOffsets,
				interactiveCheckboxes: interactiveCheckboxes)
			let html = MarkdownHTMLRenderer.wrapDocument(
				body: fragments.lazy.map(\.html).joined(), theme: theme, fontSize: fontSize,
				embedMermaidEngine: embedMermaidEngine, mermaidEngineViaScheme: true)
			return (html, fragments)
		}
		return await withTaskCancellationHandler(
			operation: { await worker.value },
			onCancel: { worker.cancel() })
	}
}
