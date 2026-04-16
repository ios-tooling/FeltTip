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
		let webView = WKWebView(frame: .zero, configuration: config)
		webView.setValue(false, forKey: "drawsBackground")
		webView.navigationDelegate = context.coordinator
		loadSVG(in: webView)
		return webView
	}

	func updateNSView(_ webView: WKWebView, context: Context) {}

	func makeCoordinator() -> Coordinator { Coordinator() }

	private func loadSVG(in webView: WKWebView) {
		let html = """
		<!DOCTYPE html>
		<html><head><meta charset="utf-8">
		<style>
		  * { margin: 0; padding: 0; }
		  body { background: transparent; display: flex; justify-content: center; }
		  img { max-width: \(Int(maxWidth))px; max-height: \(Int(maxHeight))px; height: auto; }
		</style></head>
		<body><img src="\(url.absoluteString)"></body></html>
		"""
		webView.loadHTMLString(html, baseURL: url)
	}

	final class Coordinator: NSObject, WKNavigationDelegate {
		func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
			webView.evaluateJavaScript("document.querySelector('img').naturalHeight") { height, _ in
				if let h = height as? CGFloat, h > 0 {
					webView.evaluateJavaScript("document.querySelector('img').naturalWidth") { width, _ in
						if let w = width as? CGFloat, w > 0 {
							let aspect = w / h
							let finalW = min(w, webView.bounds.width)
							let finalH = finalW / aspect
							webView.frame.size.height = finalH
							webView.invalidateIntrinsicContentSize()
						}
					}
				}
			}
		}
	}
}
#endif
