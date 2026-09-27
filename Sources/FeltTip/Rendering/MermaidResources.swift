//
//  MermaidResources.swift
//  FeltTip
//
//  Bundled mermaid engine + HTML template, cached. Used by the HTML renderer
//  (MarkdownWebView injects the engine to render mermaid code blocks) and the
//  SVG renderer. Lives outside the (removed) SwiftUI view layer that originally
//  hosted it.
//

import Foundation

public enum MermaidResources: Sendable {
	/// Swift guarantees thread-safe, once-only initialization for static lets.
	/// Renders can begin concurrently, so mutable unsynchronized caches here
	/// would race and could repeat the multi-megabyte resource load.
	private static let cachedEngineJS: String? = {
		guard let url = Bundle.module.url(forResource: "mermaid.min", withExtension: "js")
		else { return nil }
		return try? String(contentsOf: url, encoding: .utf8)
	}()

	private static let cachedTemplate: String? = {
		guard let js = cachedEngineJS,
			  let url = Bundle.module.url(forResource: "mermaid-template", withExtension: "html"),
			  let template = try? String(contentsOf: url, encoding: .utf8)
		else { return nil }
		return template.replacingOccurrences(of: "MERMAID_JS_PLACEHOLDER", with: js)
	}()

	public static func html(for code: String, theme: String) -> String? {
		cachedTemplate
	}

	/// The raw bundled `mermaid.min.js`, cached. Used by the HTML viewer
	/// (`MarkdownWebView`) to inject the engine into an already-rendered
	/// document so its mermaid code blocks render as diagrams.
	public static var engineJS: String? {
		cachedEngineJS
	}
}
