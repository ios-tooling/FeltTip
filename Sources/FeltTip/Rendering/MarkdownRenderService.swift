//
//  MarkdownRenderService.swift
//  FeltTip
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

	struct DocumentHTML: Sendable {
		let html: String
		let fragments: [MarkdownBlockFragment]
	}

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
		guard let body = joinedBody(fragments) else { return nil }
		return jsonString(for: body) ?? "\"\""
	}

	/// Cancellation-aware fragment concatenation shared by incremental
	/// full-swap fallback and initial/full document loads. A superseded render
	/// should release its per-document actor before assembling obsolete HTML.
	private static func joinedBody(_ fragments: [MarkdownBlockFragment]) -> String? {
		guard !Task.isCancelled else { return nil }
		var body = ""
		for (index, fragment) in fragments.enumerated() {
			if index & 63 == 0, Task.isCancelled { return nil }
			body += fragment.html
		}
		guard !Task.isCancelled else { return nil }
		return body
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
	) async -> DocumentHTML {
		let timingEnabled = UserDefaults.standard.bool(forKey: "MarkerTiming")
		let startedAt = timingEnabled ? CFAbsoluteTimeGetCurrent() : 0
		let fragments = MarkdownHTMLRenderer.renderBlockFragments(
			markdown: markdown, theme: theme, fontSize: fontSize,
			includeSourceOffsets: includeSourceOffsets,
			interactiveCheckboxes: interactiveCheckboxes)
		let fragmentsReadyAt = timingEnabled ? CFAbsoluteTimeGetCurrent() : 0
		guard let body = Self.joinedBody(fragments) else {
			return DocumentHTML(html: "", fragments: [])
		}
		let html = MarkdownHTMLRenderer.wrapDocument(
			body: body, theme: theme, fontSize: fontSize,
			embedMermaidEngine: embedMermaidEngine, mermaidEngineViaScheme: true,
			contentSecurityPolicy: allowRemoteResources.map {
				MarkdownHTMLRenderer.webViewContentSecurityPolicy(allowRemoteResources: $0)
			})
		if timingEnabled {
			let finishedAt = CFAbsoluteTimeGetCurrent()
			let line = String(
				format: "[TIMING] styled HTML phases: fragments=%.1f wrap=%.1f total=%.1f ms\n",
				(fragmentsReadyAt - startedAt) * 1_000,
				(finishedAt - fragmentsReadyAt) * 1_000,
				(finishedAt - startedAt) * 1_000)
			FileHandle.standardError.write(Data(line.utf8))
		}
		guard !Task.isCancelled else { return DocumentHTML(html: "", fragments: []) }
		return DocumentHTML(html: html, fragments: fragments)
	}
}
