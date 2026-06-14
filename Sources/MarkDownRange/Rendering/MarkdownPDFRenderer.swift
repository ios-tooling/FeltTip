//
//  MarkdownPDFRenderer.swift
//  MarkDownRange
//

#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import WebKit

/// Renders a markdown HTML document into a paginated, letter-sized PDF entirely
/// off-screen — no visible window required.
///
/// `WKWebView.printOperation(with:)` crashes in `_validatePagination` on modern
/// macOS, so each page is captured at 1:1 via `WKPDFConfiguration.rect` and the
/// slices are stitched together with a `CGContext` PDF. (A single `createPDF`
/// page is clamped to ~14400pt, which silently truncates long documents.) Page
/// breaks are nudged so an unbreakable element is never split across a boundary.
@MainActor
public enum MarkdownPDFRenderer {
	public static let pageWidth: CGFloat = 612    // US Letter, points
	public static let pageHeight: CGFloat = 792

	/// Render a full HTML document (as produced by
	/// `MarkdownHTMLRenderer.renderDocument`) into PDF data. Returns nil if the
	/// web content fails to load or no graphics context can be created.
	public static func pdfData(html: String, fontSize: CGFloat = 13, margin: CGFloat = 36) async -> Data? {
		let printW = pageWidth - 2 * margin
		let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: printW, height: pageHeight))
		let loader = PDFWebViewLoader()
		webView.navigationDelegate = loader
		webView.loadHTMLString(injectingPrintCSS(into: html, fontSize: fontSize), baseURL: nil)
		do { try await loader.waitForLoad() } catch { return nil }

		// Expand to full content height so createPDF captures the whole document.
		var cssHeight = pageHeight
		if let raw = try? await webView.evaluateJavaScript("document.documentElement.scrollHeight"),
		   let h = (raw as? Double).map({ CGFloat($0) }), h > 0 {
			cssHeight = h
			webView.setFrameSize(NSSize(width: printW, height: h))
			// Force a re-layout at the new size before snapshotting.
			_ = try? await webView.evaluateJavaScript("window.getComputedStyle(document.body).height")
		}

		let boxes = await unbreakableBoxes(in: webView)
		let headings = await headingBoxes(in: webView)
		let result = await paginate(webView: webView, contentHeight: cssHeight, margin: margin, unbreakable: boxes, headings: headings)
		_ = loader
		return result
	}

	/// Print-only overrides injected ahead of the renderer's own styles. A later
	/// `<style>` wins on equal specificity, so this tunes the printed output
	/// without touching the shared exporter CSS.
	static func injectingPrintCSS(into html: String, fontSize: CGFloat) -> String {
		let css = """
		<style>
		body { font-size: \(Int(fontSize))px; padding: 0; }
		table { table-layout: fixed; width: 100%; }
		th, td { overflow-wrap: anywhere; word-break: break-word; }
		pre { white-space: pre-wrap; overflow-wrap: anywhere; }
		code { overflow-wrap: anywhere; word-break: break-word; }
		</style>
		"""
		return html.replacingOccurrences(of: "</head>", with: css + "</head>")
	}

	/// Document-relative top + height (CSS px) of elements we don't want split
	/// across a page boundary. Fed to the slicer so it can nudge page breaks.
	static func unbreakableBoxes(in webView: WKWebView) async -> [(top: CGFloat, height: CGFloat)] {
		await boxes(in: webView, selector: "pre, table, img, blockquote, p, div, tr, h1, h2, h3, h4, h5, h6, li")
	}

	/// Headings only — used to avoid leaving a heading widowed at a page bottom.
	static func headingBoxes(in webView: WKWebView) async -> [(top: CGFloat, height: CGFloat)] {
		await boxes(in: webView, selector: "h1, h2, h3, h4, h5, h6")
	}

	private static func boxes(in webView: WKWebView, selector: String) async -> [(top: CGFloat, height: CGFloat)] {
		let js = """
		JSON.stringify(Array.from(document.querySelectorAll('\(selector)'))
			.map(function(e){ var r = e.getBoundingClientRect(); return [r.top + window.scrollY, r.height]; }))
		"""
		guard let result = try? await webView.evaluateJavaScript(js),
			  let raw = result as? String,
			  let data = raw.data(using: .utf8),
			  let arr = try? JSONDecoder().decode([[Double]].self, from: data)
		else { return [] }
		return arr.compactMap { $0.count == 2 ? (CGFloat($0[0]), CGFloat($0[1])) : nil }
	}
}

/// Drives a `WKWebView` load to completion via async/await.
@MainActor
final class PDFWebViewLoader: NSObject, WKNavigationDelegate {
	private var continuation: CheckedContinuation<Void, Error>?

	func waitForLoad() async throws {
		try await withCheckedThrowingContinuation { self.continuation = $0 }
	}

	private func resume(throwing error: Error? = nil) {
		guard let continuation else { return }
		self.continuation = nil
		if let error { continuation.resume(throwing: error) } else { continuation.resume() }
	}

	func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { resume() }
	func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { resume(throwing: error) }
	func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { resume(throwing: error) }
}
#endif
