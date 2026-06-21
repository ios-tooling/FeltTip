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
	/// When true, `renderInline` tags each run with a `data-s` source offset for
	/// the editable webview. Scoped per-render via a task-local (set by
	/// `renderDocument`) so it's concurrency-safe — a background export render
	/// and a foreground editable render don't clobber each other's flag.
	@TaskLocal static var emitSourceOffsets = false

	/// When true, task-list `<input type="checkbox">` elements render enabled
	/// (not `disabled`) and carry a `data-cb` attribute with their
	/// document-wide checkbox index, so an interactive host (the QuickLook
	/// webview) can map a click back to the source. Exports/PDF leave this off
	/// so their checkboxes stay static. Scoped per-render like
	/// `emitSourceOffsets`.
	@TaskLocal static var emitInteractiveCheckboxes = false

	/// Maps a mermaid block's source to pre-rendered diagram markup — an inline
	/// `<svg>` (HTML/PDF export) or an `<img>` data URI (DOCX/rich text). When a
	/// code block's source has an entry, `renderBlock` emits that markup instead
	/// of the raw mermaid source (see `MarkdownMermaidPrerender`). Scoped
	/// per-render.
	@TaskLocal static var prerenderedMermaidDiagrams: [String: String] = [:]

	/// Renders the given parsed blocks to a body-only HTML fragment — no
	/// `<html>`/`<head>`/`<body>` wrapper. Caller-supplied themes apply at
	/// the document level (see `renderDocument`).
	public static func renderBlocks(_ blocks: [MarkdownBlock]) -> String {
		var output = ""
		output.reserveCapacity(blocks.count * 256)
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
		options: MarkdownOptions = .default,
		includeSourceOffsets: Bool = false,
		interactiveCheckboxes: Bool = false,
		embedMermaidEngine: Bool = false,
		mermaidDiagrams: [String: String] = [:]
	) -> String {
		// Editable rendering tracks source offsets through preprocessing so the
		// `data-s` offsets address the caller's text while highlight/smart
		// quotes/emoji still render.
		let blocks = includeSourceOffsets
			? MarkdownBlockParser.parse(markdown, theme: theme, fontSize: fontSize, trackSourceOffsets: true, options: options)
			: MarkdownBlockParser.parse(markdown, theme: theme, fontSize: fontSize, options: options)
		let body = $emitSourceOffsets.withValue(includeSourceOffsets) {
			$emitInteractiveCheckboxes.withValue(interactiveCheckboxes) {
				$prerenderedMermaidDiagrams.withValue(mermaidDiagrams) { renderBlocks(blocks) }
			}
		}
		let mermaid = embedMermaidEngine ? mermaidEmbed(forBody: body, theme: theme) : ""
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
		\(mermaid)
		</body>
		</html>
		"""
	}

	/// Inline `<script>` block that bundles the mermaid engine and renders the
	/// document's mermaid code blocks as diagrams. Embedded directly in the HTML
	/// (rather than injected post-load) so it runs everywhere the document is
	/// shown — including the QuickLook extension, whose WKWebView doesn't run
	/// `evaluateJavaScript`/`didFinish` injections reliably. Empty when there are
	/// no mermaid blocks (keeps the ~3 MB engine off ordinary documents).
	private static func mermaidEmbed(forBody body: String, theme: MarkdownTheme) -> String {
		#if os(macOS)
		guard body.contains("language-mermaid"), let engine = MermaidResources.engineJS else { return "" }
		return """
		<script>\(engine)</script>
		<script>
		(function () {
		  document.querySelectorAll('pre > code.language-mermaid').forEach(function (code) {
		    var div = document.createElement('div');
		    div.className = 'mermaid';
		    div.textContent = code.textContent;
		    code.parentElement.replaceWith(div);
		  });
		  try {
		    mermaid.initialize({ startOnLoad: false, theme: '\(theme.mermaidTheme)', securityLevel: 'strict', fontFamily: '-apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif' });
		    mermaid.run({ querySelector: '.mermaid' });
		  } catch (e) {}
		})();
		</script>
		"""
		#else
		return ""
		#endif
	}
}
