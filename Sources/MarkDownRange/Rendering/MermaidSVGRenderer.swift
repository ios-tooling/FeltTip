//
//  MermaidSVGRenderer.swift
//  MarkDownRange
//
//  Pre-renders mermaid code blocks to standalone inline SVG using the bundled
//  engine in an offscreen WKWebView. Export paths (HTML / PDF) embed the
//  resulting SVG in place of the raw code, so the diagram is self-contained —
//  no JS engine ships in the output, and it renders identically in any viewer.
//  Inline SVG (not a base64 `<img>`) because mermaid labels use `<foreignObject>`,
//  which doesn't render when an SVG is loaded as an image.
//

#if os(macOS)
import Foundation
import WebKit

@MainActor
public final class MermaidSVGRenderer {
	private let webView: WKWebView
	private let loader = MermaidLoadWaiter()
	private var initialized = false

	public init() {
		webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
		webView.navigationDelegate = loader
	}

	/// Renders each distinct mermaid source to an inline SVG string. Sources that
	/// fail to render are omitted from the result (the caller falls back to the
	/// raw code block), so a single malformed diagram can't sink the export.
	public func renderSVGs(for sources: [String], theme: String) async -> [String: String] {
		guard !sources.isEmpty, let engine = MermaidResources.engineJS else { return [:] }
		await initialize(engine: engine, theme: theme)
		var result: [String: String] = [:]
		for source in sources where result[source] == nil {
			if let svg = await render(source) { result[source] = svg }
		}
		return result
	}

	private func initialize(engine: String, theme: String) async {
		if initialized { return }
		let html = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><script>\(engine)</script></head><body></body></html>"
		webView.loadHTMLString(html, baseURL: nil)
		await loader.wait()
		_ = try? await webView.callAsyncJavaScript(
			"mermaid.initialize({ startOnLoad: false, theme: t, securityLevel: 'strict', fontFamily: '-apple-system, BlinkMacSystemFont, \"SF Pro Text\", sans-serif' });",
			arguments: ["t": theme], contentWorld: .page)
		initialized = true
	}

	private func render(_ source: String) async -> String? {
		let js = "const { svg } = await mermaid.render('mmd-' + Math.floor(Math.random() * 1e9), src); return svg;"
		let result = try? await webView.callAsyncJavaScript(js, arguments: ["src": source], contentWorld: .page)
		return result as? String
	}
}

private final class MermaidLoadWaiter: NSObject, WKNavigationDelegate {
	private var continuation: CheckedContinuation<Void, Never>?

	func wait() async {
		await withCheckedContinuation { continuation = $0 }
	}

	private func resume() {
		guard let continuation else { return }
		self.continuation = nil
		continuation.resume()
	}

	func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { resume() }
	func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { resume() }
	func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { resume() }
}
#endif
