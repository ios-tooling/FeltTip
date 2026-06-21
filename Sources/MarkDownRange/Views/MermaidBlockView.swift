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

	@State private var renderedSize = CGSize(width: 0, height: 200)
	@State private var hasError = false
	@State private var isContentHovering = false
	@State private var isButtonHovering = false

	var body: some View {
		if hasError {
			CodeBlockView(code: code, language: "mermaid", theme: theme)
		} else {
			ZStack(alignment: .topTrailing) {
				MermaidWebView(
					code: code,
					mermaidTheme: theme.mermaidTheme,
					renderedSize: $renderedSize,
					hasError: $hasError
				)
				.frame(height: max(50, renderedSize.height + 16))
				.clipShape(RoundedRectangle(cornerRadius: 8))

				popoutButton
			}
			.contentShape(Rectangle())
			.onHover { isContentHovering = $0 }
		}
	}

	@ViewBuilder private var popoutButton: some View {
		if MarkdownImageSizing.shouldOfferPopout(for: renderedSize) {
			MarkdownAccessoryButton(
				systemImage: "arrow.up.left.and.arrow.down.right",
				theme: theme,
				label: "Pop out mermaid diagram"
			) {
				MermaidPopoutPanelController.shared.present(
					code: code,
					mermaidTheme: theme.mermaidTheme,
					initialDiagramSize: renderedSize
				)
			}
			.padding(12)
			.opacity((isContentHovering || isButtonHovering) ? 1 : 0)
			.allowsHitTesting(isContentHovering || isButtonHovering)
			.onHover { isButtonHovering = $0 }
			.animation(.easeInOut(duration: 0.15), value: isContentHovering)
			.animation(.easeInOut(duration: 0.15), value: isButtonHovering)
			.animation(.easeInOut(duration: 0.15), value: renderedSize)
		}
	}
}

struct MermaidWebView: NSViewRepresentable {
	let code: String
	let mermaidTheme: String
	var zoomScale: CGFloat = 1
	@Binding var renderedSize: CGSize
	@Binding var hasError: Bool
	var onNaturalSizeChanged: ((CGSize) -> Void)? = nil

	func makeNSView(context: Context) -> WKWebView {
		let config = WKWebViewConfiguration()
		let handler = context.coordinator
		config.userContentController.add(handler, name: "mermaid")

		let webView = EventPassthroughWKWebView(frame: .zero, configuration: config)
		webView.navigationDelegate = handler
		webView.setValue(false, forKey: "drawsBackground")
		loadPage(in: webView)
		return webView
	}

	func updateNSView(_ webView: WKWebView, context: Context) {
		let coordinator = context.coordinator
		coordinator.parent = self
		if coordinator.lastCode != code || coordinator.lastTheme != mermaidTheme {
			coordinator.lastCode = code
			coordinator.lastTheme = mermaidTheme
			coordinator.lastZoomScale = zoomScale
			if coordinator.pageLoaded {
				renderViaJS(in: webView)
			} else {
				loadPage(in: webView)
			}
		} else if coordinator.lastZoomScale != zoomScale, coordinator.pageLoaded {
			coordinator.lastZoomScale = zoomScale
			updateZoom(in: webView)
		}
	}

	private func loadPage(in webView: WKWebView) {
		guard let html = MermaidResources.html(for: code, theme: mermaidTheme) else {
			hasError = true
			return
		}
		webView.loadHTMLString(html, baseURL: nil)
	}

	private func renderViaJS(in webView: WKWebView) {
		let escaped = Self.escapeForJS(code)
		webView.evaluateJavaScript("renderDiagram(`\(escaped)`, '\(mermaidTheme)', \(Self.scaleLiteral(zoomScale)))")
	}

	private func updateZoom(in webView: WKWebView) {
		webView.evaluateJavaScript("updateScale(\(Self.scaleLiteral(zoomScale)))")
	}

	static func escapeForJS(_ code: String) -> String {
		code.replacingOccurrences(of: "\\", with: "\\\\")
			.replacingOccurrences(of: "`", with: "\\`")
			.replacingOccurrences(of: "$", with: "\\$")
			.replacingOccurrences(of: "\n", with: "\\n")
	}

	static func scaleLiteral(_ zoomScale: CGFloat) -> String {
		String(Double(zoomScale))
	}

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
		var parent: MermaidWebView
		var lastCode: String
		var lastTheme: String
		var lastZoomScale: CGFloat
		var pageLoaded = false

		init(_ parent: MermaidWebView) {
			self.parent = parent
			self.lastCode = parent.code
			self.lastTheme = parent.mermaidTheme
			self.lastZoomScale = parent.zoomScale
		}

		func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
			guard let body = message.body as? [String: Any] else { return }
			let type = body["type"] as? String

			if type == "rendered",
			   let widthValue = body["width"] as? NSNumber,
			   let heightValue = body["height"] as? NSNumber {
				let size = CGSize(
					width: max(0, CGFloat(widthValue.doubleValue)),
					height: max(50, CGFloat(heightValue.doubleValue))
				)
				let naturalWidth = (body["naturalWidth"] as? NSNumber).map { CGFloat($0.doubleValue) }
				let naturalHeight = (body["naturalHeight"] as? NSNumber).map { CGFloat($0.doubleValue) }
				let naturalSize = CGSize(
					width: max(0, naturalWidth ?? size.width),
					height: max(50, naturalHeight ?? size.height)
				)
				Task { @MainActor in
					parent.renderedSize = size
					parent.onNaturalSizeChanged?(naturalSize)
				}
			} else if type == "error" {
				Task { @MainActor in parent.hasError = true }
			}
		}

		func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
			pageLoaded = true
			let escaped = MermaidWebView.escapeForJS(parent.code)
			webView.evaluateJavaScript("renderDiagram(`\(escaped)`, '\(parent.mermaidTheme)', \(MermaidWebView.scaleLiteral(parent.zoomScale)))")
		}
	}
}

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
#endif
