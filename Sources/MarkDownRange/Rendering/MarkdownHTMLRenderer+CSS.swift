//
//  MarkdownHTMLRenderer+CSS.swift
//  MarkDownRange
//

import Foundation
import SwiftUI

extension MarkdownHTMLRenderer {
	/// Stylesheet matching the live preview's appearance under `theme`. Exports
	/// can drop this into a `<style>` block to keep PDF/HTML output visually
	/// aligned with what the user sees in the editor preview.
	public static func css(for theme: MarkdownTheme, fontSize: CGFloat = 16) -> String {
		let bodyFont = fontFamilyStack(for: theme.fontFamily)
		return """
		body {
			font-family: \(bodyFont);
			font-size: \(Int(fontSize))px;
			line-height: 1.6;
			color: \(rgba(theme.textColor));
			background: \(rgba(theme.backgroundColor));
			max-width: 860px;
			margin: 0 auto;
			padding: 32px;
		}
		h1, h2, h3, h4, h5, h6 {
			color: \(rgba(theme.headingColor));
			margin-top: 1.5em;
			margin-bottom: 0.5em;
		}
		h1 { font-size: 2em; }
		h2 { font-size: 1.5em; }
		h3 { font-size: 1.25em; }
		h4 { font-size: 1.1em; }
		a { color: \(rgba(theme.linkColor)); text-decoration: none; }
		a:hover { text-decoration: underline; }
		code {
			font-family: ui-monospace, "SF Mono", Menlo, monospace;
			font-size: 0.875em;
			background: \(rgba(theme.codeBackground));
			color: \(rgba(theme.codeForeground));
			padding: 2px 6px;
			border-radius: 4px;
		}
		pre {
			background: \(rgba(theme.codeBackground));
			color: \(rgba(theme.codeForeground));
			padding: 16px;
			border-radius: 6px;
			white-space: pre-wrap;
			overflow-wrap: anywhere;
		}
		pre code { background: none; padding: 0; }
		/* Server-side syntax highlighting (see Tokenizer.highlightedHTML).
		   Standard system-color palette, legible on light and dark code
		   backgrounds alike. */
		.tok-keyword { color: #AF52DE; }
		.tok-type    { color: #30B0C7; }
		.tok-string  { color: #D70015; }
		.tok-number  { color: #0A84FF; }
		.tok-comment { color: #8E8E93; font-style: italic; }
		@media (prefers-color-scheme: dark) {
			.tok-keyword { color: #DA8FFF; }
			.tok-type    { color: #5AC8FA; }
			.tok-string  { color: #FF6961; }
			.tok-number  { color: #64D2FF; }
			.tok-comment { color: #98989D; }
		}
		blockquote {
			border-left: 4px solid \(rgba(theme.secondaryColor, alpha: 0.4));
			margin: 1em 0;
			padding: 0.5em 1em;
			color: \(rgba(theme.secondaryColor));
		}
		hr {
			border: none;
			border-top: 1px solid \(rgba(theme.secondaryColor, alpha: 0.3));
			margin: 2em 0;
		}
		img { max-width: 100%; height: auto; }
		::highlight(md-mirror) { background-color: \(rgba(theme.mirrorHighlightColor)); }
		.mermaid-diagram { text-align: center; margin: 1em 0; }
		.mermaid-diagram svg { max-width: 100%; height: auto; }
		.image-row {
			display: flex;
			align-items: flex-start;
			gap: 8px;
			flex-wrap: wrap;
			margin: 1em 0;
		}
		.image-row img,
		.image-row a {
			flex: 0 0 auto;
		}
		.image-row a {
			display: inline-flex;
			align-items: flex-start;
		}
		table {
			border-collapse: collapse;
			width: 100%;
			margin: 1em 0;
		}
		th, td {
			border: 1px solid \(rgba(theme.secondaryColor, alpha: 0.3));
			padding: 8px 12px;
			text-align: left;
		}
		th {
			background: \(rgba(theme.codeBackground));
			font-weight: 600;
		}
		\(alternateRowCSS(theme))
		dl { margin: 1em 0; }
		dt { font-weight: 600; margin-top: 0.5em; }
		dd { margin-left: 1.5em; color: \(rgba(theme.secondaryColor)); }
		details { margin: 1em 0; }
		summary { cursor: pointer; font-weight: 600; }
		.alert {
			border-left: 4px solid;
			padding: 0.5em 1em;
			margin: 1em 0;
			border-radius: 4px;
		}
		.alert-label {
			font-weight: 600;
			margin-bottom: 0.25em;
			text-transform: uppercase;
			font-size: 0.875em;
		}
		.alert-note { border-left-color: #0969da; background: rgba(9, 105, 218, 0.08); }
		.alert-tip { border-left-color: #1a7f37; background: rgba(26, 127, 55, 0.08); }
		.alert-important { border-left-color: #8250df; background: rgba(130, 80, 223, 0.08); }
		.alert-warning { border-left-color: #9a6700; background: rgba(154, 103, 0, 0.08); }
		.alert-caution { border-left-color: #cf222e; background: rgba(207, 34, 46, 0.08); }
		.frontmatter {
			width: auto;
			font-size: 0.875em;
			margin-bottom: 1.5em;
			opacity: 0.85;
		}
		.frontmatter th {
			background: none;
			font-weight: 600;
			text-align: right;
		}
		input[type="checkbox"] {
			margin-right: 0.4em;
		}
		"""
	}

	private static func alternateRowCSS(_ theme: MarkdownTheme) -> String {
		guard let alt = theme.alternateRowBackground else { return "" }
		return "tbody tr:nth-child(even) { background: \(rgba(alt)); }"
	}

	private static func fontFamilyStack(for family: MarkdownFontFamily) -> String {
		switch family {
		case .system: return "-apple-system, BlinkMacSystemFont, \"Helvetica Neue\", system-ui, sans-serif"
		case .serif: return "ui-serif, \"New York\", \"Times New Roman\", Times, serif"
		case .rounded: return "ui-rounded, \"SF Pro Rounded\", -apple-system, sans-serif"
		case .mono: return "ui-monospace, \"SF Mono\", Menlo, monospace"
		}
	}

	private static func rgba(_ color: Color, alpha: Double? = nil) -> String {
		let c = color.components
		let r = Int((c.r * 255).rounded())
		let g = Int((c.g * 255).rounded())
		let b = Int((c.b * 255).rounded())
		let a = alpha ?? c.a
		return "rgba(\(r), \(g), \(b), \(String(format: "%.3f", a)))"
	}
}
