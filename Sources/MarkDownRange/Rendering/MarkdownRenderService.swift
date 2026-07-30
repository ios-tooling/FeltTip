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
		/// The incremental patch and its JSON payload are planned on the render
		/// actor so a large suffix scan and JSON encoding never land on the UI
		/// actor. A patch result deliberately omits `bodyJSON`: serializing the
		/// entire document on every one-block edit was pure wasted work.
		let patch: MarkdownBlockPatch?
		let patchHTMLJSON: String?
		/// Present when the baseline proves a full swap is required. If WebKit
		/// unexpectedly refuses an incremental patch, the coordinator requests
		/// this payload lazily through `bodyJSON(for:)`.
		let bodyJSON: String?
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
		MarkdownHTMLRenderer.renderBlockFragments(
			markdown: markdown, theme: theme, fontSize: fontSize,
			includeSourceOffsets: includeSourceOffsets,
			interactiveCheckboxes: interactiveCheckboxes)
	}

	func blockResult(
		markdown: String, theme: MarkdownTheme, fontSize: CGFloat,
		includeSourceOffsets: Bool, interactiveCheckboxes: Bool,
		baseline: [MarkdownBlockFragment]? = nil
	) -> BlockResult {
		let fragments = MarkdownHTMLRenderer.renderBlockFragments(
			markdown: markdown, theme: theme, fontSize: fontSize,
			includeSourceOffsets: includeSourceOffsets,
			interactiveCheckboxes: interactiveCheckboxes)
		if let baseline,
		   let patch = MarkdownBlockDiff.patch(from: baseline, to: fragments),
		   let patchHTMLJSON = Self.jsonString(for: patch.html) {
			return BlockResult(
				fragments: fragments,
				patch: patch,
				patchHTMLJSON: patchHTMLJSON,
				bodyJSON: nil)
		}
		return BlockResult(
			fragments: fragments,
			patch: nil,
			patchHTMLJSON: nil,
			bodyJSON: Self.bodyJSON(fragments))
	}

	func bodyJSON(for fragments: [MarkdownBlockFragment]) -> String? {
		Self.bodyJSON(fragments)
	}

	private static func bodyJSON(_ fragments: [MarkdownBlockFragment]) -> String? {
		guard !Task.isCancelled else { return nil }
		var body = ""
		for (index, fragment) in fragments.enumerated() {
			if index & 63 == 0, Task.isCancelled { return nil }
			body += fragment.html
		}
		guard !Task.isCancelled else { return nil }
		return jsonString(for: body) ?? "\"\""
	}

	private static func jsonString<Value: Encodable>(for value: Value) -> String? {
		(try? JSONEncoder().encode(value))
			.flatMap { String(data: $0, encoding: .utf8) }
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
