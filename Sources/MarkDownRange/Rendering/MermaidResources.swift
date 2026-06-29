//
//  MermaidResources.swift
//  MarkDownRange
//
//  Bundled mermaid engine + HTML template, cached. Used by the HTML renderer
//  (MarkdownWebView injects the engine to render mermaid code blocks) and the
//  SVG renderer. Lives outside the (removed) SwiftUI view layer that originally
//  hosted it.
//

import Foundation

public enum MermaidResources: Sendable {
	nonisolated(unsafe) private static var cachedTemplate: String?
	nonisolated(unsafe) private static var cachedEngineJS: String?

	public static func html(for code: String, theme: String) -> String? {
		loadTemplate()
	}

	/// The raw bundled `mermaid.min.js`, cached. Used by the HTML viewer
	/// (`MarkdownWebView`) to inject the engine into an already-rendered
	/// document so its mermaid code blocks render as diagrams.
	public static var engineJS: String? {
		if let cachedEngineJS { return cachedEngineJS }
		guard let resourceURL = Bundle.module.url(forResource: "Resources", withExtension: nil) else { return nil }
		guard let js = try? String(contentsOf: resourceURL.appendingPathComponent("mermaid.min.js")) else { return nil }
		cachedEngineJS = js
		return js
	}

	private static func loadTemplate() -> String? {
		if let cached = cachedTemplate { return cached }
		guard let resourceURL = Bundle.module.url(forResource: "Resources", withExtension: nil) else { return nil }
		let jsURL = resourceURL.appendingPathComponent("mermaid.min.js")
		let templateURL = resourceURL.appendingPathComponent("mermaid-template.html")

		guard let js = try? String(contentsOf: jsURL),
			  let template = try? String(contentsOf: templateURL) else { return nil }

		let result = template.replacingOccurrences(of: "MERMAID_JS_PLACEHOLDER", with: js)
		cachedTemplate = result
		return result
	}
}
