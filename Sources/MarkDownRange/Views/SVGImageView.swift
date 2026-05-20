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
	/// Called once when the `<img>` inside the WebView fails to load (broken
	/// URL, network error, decode failure, etc.). Lets the parent swap in a
	/// labeled placeholder instead of leaving the WKWebView's tiny broken-
	/// image glyph in place.
	var onLoadFailure: (() -> Void)?

	func makeNSView(context: Context) -> WKWebView {
		let config = WKWebViewConfiguration()
		config.websiteDataStore = .nonPersistent()
		let handler = context.coordinator
		config.userContentController.add(handler, name: "size")
		config.userContentController.add(handler, name: "loadFailed")
		let webView = EventPassthroughWKWebView(frame: .zero, configuration: config)
		webView.setValue(false, forKey: "drawsBackground")
		webView.navigationDelegate = context.coordinator
		context.coordinator.parent = self
		loadSVG(in: webView)
		return webView
	}

	func updateNSView(_ webView: WKWebView, context: Context) {
		context.coordinator.parent = self
		loadSVG(in: webView)
	}

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
		<body><img src="\(escaped)"
		  onload="webkit.messageHandlers.size.postMessage({w: this.naturalWidth, h: this.naturalHeight})"
		  onerror="webkit.messageHandlers.loadFailed.postMessage({})"
		></body></html>
		"""
		webView.loadHTMLString(html, baseURL: url)
	}

	final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
		var parent: SVGImageView?
		private var didReportFailure = false

		func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
			if message.name == "loadFailed" {
				reportFailure()
				return
			}
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

		func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
			reportFailure()
		}

		func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
			reportFailure()
		}

		private func reportFailure() {
			guard !didReportFailure else { return }
			didReportFailure = true
			parent?.onLoadFailure?()
		}
	}
}
#endif
