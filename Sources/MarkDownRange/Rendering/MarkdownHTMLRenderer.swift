//
//  MarkdownHTMLRenderer.swift
//  MarkDownRange
//
//  Emits HTML from the canonical `[MarkdownBlock]` model so HTML/PDF/DOCX
//  exports stay in lockstep with the live SwiftUI preview. The previous
//  Marker-side converter re-implemented a stripped-down parser and silently
//  dropped footnotes, alerts, wikilinks, definition lists, mermaid, etc.;
//  routing through the same parser the preview uses kills that divergence.
//

import Foundation
import SwiftUI

public enum MarkdownHTMLRenderer {
	/// Renders the given parsed blocks to a body-only HTML fragment — no
	/// `<html>`/`<head>`/`<body>` wrapper. Caller-supplied themes apply at
	/// the document level (see `renderDocument`).
	public static func renderBlocks(_ blocks: [MarkdownBlock]) -> String {
		var output = ""
		for block in blocks { output += renderBlock(block) }
		return output
	}

	/// Renders source markdown to a full standalone HTML document whose
	/// embedded CSS reflects `theme`. Use this for HTML exports, PDF
	/// rendering via WKWebView, and any other consumer that wants a
	/// self-contained document.
	public static func renderDocument(
		markdown: String,
		theme: MarkdownTheme = .default,
		fontSize: CGFloat = 16,
		options: MarkdownOptions = .default
	) -> String {
		let blocks = MarkdownBlockParser.parse(markdown, theme: theme, fontSize: fontSize, options: options)
		let body = renderBlocks(blocks)
		return """
		<!DOCTYPE html>
		<html>
		<head>
		<meta charset="utf-8">
		<meta name="viewport" content="width=device-width, initial-scale=1">
		<style>\(css(for: theme, fontSize: fontSize))</style>
		</head>
		<body>
		\(body)
		</body>
		</html>
		"""
	}
}
