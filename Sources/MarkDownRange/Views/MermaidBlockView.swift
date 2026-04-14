//
//  MermaidBlockView.swift
//  MarkDownRange
//

#if os(macOS)
import SwiftUI
import WebKit

struct MermaidBlockView: View {
	let code: String
	let theme: MarkdownTheme

	@State private var renderedHeight: CGFloat = 200
	@State private var hasError = false

	var body: some View {
		if hasError {
			CodeBlockView(code: code, language: "mermaid", theme: theme)
		} else {
			MermaidWebView(
				code: code,
				mermaidTheme: theme.mermaidTheme,
				renderedHeight: $renderedHeight,
				hasError: $hasError
			)
			.frame(height: renderedHeight)
			.clipShape(RoundedRectangle(cornerRadius: 8))
		}
	}
}

private struct MermaidWebView: NSViewRepresentable {
	let code: String
	let mermaidTheme: String
	@Binding var renderedHeight: CGFloat
	@Binding var hasError: Bool

	func makeNSView(context: Context) -> WKWebView {
		let config = WKWebViewConfiguration()
		let handler = context.coordinator
		config.userContentController.add(handler, name: "mermaid")

		let webView = WKWebView(frame: .zero, configuration: config)
		webView.navigationDelegate = handler
		webView.setValue(false, forKey: "drawsBackground")
		loadDiagram(in: webView)
		return webView
	}

	func updateNSView(_ webView: WKWebView, context: Context) {
		let coordinator = context.coordinator
		if coordinator.lastCode != code || coordinator.lastTheme != mermaidTheme {
			coordinator.lastCode = code
			coordinator.lastTheme = mermaidTheme
			loadDiagram(in: webView)
		}
	}

	private func loadDiagram(in webView: WKWebView) {
		guard let html = MermaidResources.html(for: code, theme: mermaidTheme) else {
			hasError = true
			return
		}
		webView.loadHTMLString(html, baseURL: nil)
	}

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
		var parent: MermaidWebView
		var lastCode: String
		var lastTheme: String

		init(_ parent: MermaidWebView) {
			self.parent = parent
			self.lastCode = parent.code
			self.lastTheme = parent.mermaidTheme
		}

		func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
			guard let body = message.body as? [String: Any] else { return }
			let type = body["type"] as? String

			if type == "rendered", let height = body["height"] as? CGFloat {
				Task { @MainActor in parent.renderedHeight = max(50, height + 16) }
			} else if type == "error" {
				Task { @MainActor in parent.hasError = true }
			}
		}

		func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
			let escaped = parent.code
				.replacingOccurrences(of: "\\", with: "\\\\")
				.replacingOccurrences(of: "`", with: "\\`")
				.replacingOccurrences(of: "\n", with: "\\n")
			webView.evaluateJavaScript("renderDiagram(`\(escaped)`, '\(parent.mermaidTheme)')")
		}
	}
}

public enum MermaidResources: Sendable {
	nonisolated(unsafe) private static var cachedTemplate: String?

	public static func html(for code: String, theme: String) -> String? {
		loadTemplate()
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
#endif
