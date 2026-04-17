//
//  SVGImageView.swift
//  MarkDownRange
//

#if os(macOS)
import SwiftUI
import WebKit

struct SVGImageView: NSViewRepresentable {
	let url: URL
	let maxWidth: CGFloat
	let maxHeight: CGFloat

	func makeNSView(context: Context) -> WKWebView {
		let config = WKWebViewConfiguration()
		config.websiteDataStore = .nonPersistent()
		let handler = context.coordinator
		config.userContentController.add(handler, name: "size")
		let webView = WKWebView(frame: .zero, configuration: config)
		webView.setValue(false, forKey: "drawsBackground")
		loadSVG(in: webView)
		return webView
	}

	func updateNSView(_ webView: WKWebView, context: Context) {}

	func makeCoordinator() -> Coordinator { Coordinator() }

	private func loadSVG(in webView: WKWebView) {
		let escaped = url.absoluteString
			.replacingOccurrences(of: "&", with: "&amp;")
			.replacingOccurrences(of: "\"", with: "&quot;")
			.replacingOccurrences(of: "<", with: "&lt;")
		let html = """
		<!DOCTYPE html>
		<html><head><meta charset="utf-8">
		<style>
		  * { margin: 0; padding: 0; }
		  body { background: transparent; display: flex; justify-content: center; }
		  img { max-width: \(Int(maxWidth))px; max-height: \(Int(maxHeight))px; height: auto; }
		</style></head>
		<body><img src="\(escaped)" onload="webkit.messageHandlers.size.postMessage({w: this.naturalWidth, h: this.naturalHeight})"></body></html>
		"""
		webView.loadHTMLString(html, baseURL: url)
	}

	final class Coordinator: NSObject, WKScriptMessageHandler {
		func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
			guard let dict = message.body as? [String: Any],
				  let w = dict["w"] as? CGFloat, w > 0,
				  let h = dict["h"] as? CGFloat, h > 0,
				  let webView = message.webView else { return }
			let aspect = w / h
			let finalW = min(w, webView.bounds.width)
			let finalH = finalW / aspect
			webView.frame.size.height = finalH
			webView.invalidateIntrinsicContentSize()
		}
	}
}
#endif
