//
//  MarkdownHTMLRenderer.swift
//  FeltTip
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
		for block in blocks {
			if Task.isCancelled { break }
			output += renderBlock(block)
		}
		return output
	}

	/// Renders source markdown to a full standalone HTML document whose
	/// embedded CSS reflects `theme`. Use this for HTML exports, PDF
	/// rendering via WKWebView, and any other consumer that wants a
	/// self-contained document.
	/// Renders just the body-content fragment (no document wrapper or CSS),
	/// with the same per-render flags `renderDocument` uses. The editable web
	/// view swaps this into an already-loaded page so text updates don't
	/// navigate (and flash).
	public static func renderBodyFragment(
		markdown: String,
		theme: MarkdownTheme = .default,
		fontSize: CGFloat = 16,
		options: MarkdownOptions = .default,
		includeSourceOffsets: Bool = false,
		interactiveCheckboxes: Bool = false,
		mermaidDiagrams: [String: String] = [:]
	) -> String {
		// Editable rendering tracks source offsets through preprocessing so the
		// `data-s` offsets address the caller's text while highlight/smart
		// quotes/emoji still render.
		let blocks = includeSourceOffsets
			? MarkdownBlockParser.parse(markdown, theme: theme, fontSize: fontSize, trackSourceOffsets: true, options: options)
			: MarkdownBlockParser.parse(markdown, theme: theme, fontSize: fontSize, options: options)
		return $emitSourceOffsets.withValue(includeSourceOffsets) {
			$emitInteractiveCheckboxes.withValue(interactiveCheckboxes) {
				$prerenderedMermaidDiagrams.withValue(mermaidDiagrams) { renderBlocks(blocks) }
			}
		}
	}

	public static func renderDocument(
		markdown: String,
		theme: MarkdownTheme = .default,
		fontSize: CGFloat = 16,
		options: MarkdownOptions = .default,
		includeSourceOffsets: Bool = false,
		interactiveCheckboxes: Bool = false,
		embedMermaidEngine: Bool = false,
		mermaidEngineViaScheme: Bool = false,
		mermaidDiagrams: [String: String] = [:]
	) -> String {
		let body = renderBodyFragment(
			markdown: markdown, theme: theme, fontSize: fontSize, options: options,
			includeSourceOffsets: includeSourceOffsets,
			interactiveCheckboxes: interactiveCheckboxes,
			mermaidDiagrams: mermaidDiagrams)
		return wrapDocument(body: body, theme: theme, fontSize: fontSize,
							embedMermaidEngine: embedMermaidEngine,
							mermaidEngineViaScheme: mermaidEngineViaScheme)
	}

	/// Wraps an already-rendered body fragment in the standalone document
	/// shell (doctype, CSS, optional mermaid engine). Split out so callers
	/// that render per-block fragments can build the same document from them.
	static func wrapDocument(
		body: String, theme: MarkdownTheme, fontSize: CGFloat,
		embedMermaidEngine: Bool = false, mermaidEngineViaScheme: Bool = false,
		contentSecurityPolicy: String? = nil
	) -> String {
		let mermaid = embedMermaidEngine ? mermaidEmbed(forBody: body, theme: theme, viaScheme: mermaidEngineViaScheme) : ""
		let csp = contentSecurityPolicy.map {
			"<meta http-equiv=\"Content-Security-Policy\" content=\"\($0)\">"
		} ?? ""
		return """
		<!DOCTYPE html>
		<html>
		<head>
		<meta charset="utf-8">
		<meta name="viewport" content="width=device-width, initial-scale=1">
		\(csp)
		<style>\(css(for: theme, fontSize: fontSize))</style>
		</head>
		<body>
		\(body)
		\(mermaid)
		</body>
		</html>
		"""
	}

	/// The live editor/preview policy. Inline style/script are required by the
	/// generated document and edit bridge; network-capable resource classes stay
	/// closed unless the host explicitly trusts the document.
	static func webViewContentSecurityPolicy(allowRemoteResources: Bool) -> String {
		let remote = allowRemoteResources ? " https: http:" : ""
		return [
			"default-src 'none'",
			"base-uri 'none'",
			"connect-src 'none'",
			"font-src data:",
			"form-action 'none'",
			"frame-src 'none'",
			"img-src data: markerlocalres:\(remote)",
			"media-src data: markerlocalres:\(remote)",
			"object-src 'none'",
			"script-src 'unsafe-inline' markerlocalres:",
			"style-src 'unsafe-inline'",
		].joined(separator: "; ")
	}

	/// Inline `<script>` block that bundles the mermaid engine and renders the
	/// document's mermaid code blocks as diagrams. Embedded directly in the HTML
	/// (rather than injected post-load) so it runs everywhere the document is
	/// shown — including the QuickLook extension, whose WKWebView doesn't run
	/// `evaluateJavaScript`/`didFinish` injections reliably. Empty when there are
	/// no mermaid blocks (keeps the ~3 MB engine off ordinary documents).
	/// `viaScheme` serves the ~3 MB engine through the custom resource scheme
	/// (`markerlocalres://mermaid/engine.js`) instead of inlining it into the
	/// HTML string — pages loaded in a web view that registers
	/// `LocalResourceSchemeHandler` skip the multi-megabyte string build and
	/// parse on every reload. Callers without the handler (exports, snapshot
	/// tests, QuickLook) must keep the inline embed.
	private static func mermaidEmbed(forBody body: String, theme: MarkdownTheme, viaScheme: Bool = false) -> String {
		guard body.contains("language-mermaid") else { return "" }
		let engineTag: String
		if viaScheme {
			engineTag = "<script src=\"markerlocalres://mermaid/engine.js\"></script>"
		} else if let engine = MermaidResources.engineJS {
			engineTag = "<script>\(engine)</script>"
		} else {
			return ""
		}
		return """
		\(engineTag)
		<script>
		(function () {
		  window.__mdRenderMermaid = function () {
		    var diagrams = [];
		    var candidates = document.querySelectorAll('pre > code.language-mermaid');
		    for (var i = 0; i < candidates.length && diagrams.length < 100; i++) {
		      var code = candidates[i];
		      if ((code.textContent || '').length > 1048576) continue;
		      var div = document.createElement('div');
		      div.className = 'mermaid';
		      div.contentEditable = 'false';
		      div.textContent = code.textContent;
		      code.parentElement.replaceWith(div);
		      diagrams.push(div);
		    }
		    if (!diagrams.length) return;
		    try {
		      mermaid.initialize({ startOnLoad: false, theme: '\(theme.mermaidTheme)', securityLevel: 'strict', fontFamily: '-apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif' });
		      mermaid.run({ nodes: diagrams });
		    } catch (e) {}
		  };
		  window.__mdRenderMermaid();
		})();
		</script>
		"""
	}
}
