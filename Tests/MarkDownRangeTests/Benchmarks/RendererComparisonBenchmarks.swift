//
//  RendererComparisonBenchmarks.swift
//  MarkDownRangeTests
//
//  Head-to-head "source → displayed" cost for the two styled-view renderers:
//    • NSTextView: build the NSAttributedString (incl. attachment sizing) +
//      TextKit 2 full layout.
//    • WKWebView: render HTML + loadHTMLString → didFinish (WebKit parse+layout).
//  Both share parse/preprocess, so the difference is the rendering+layout engine.
//
//  Run: RUN_BENCHMARKS=1 swift test --no-parallel --filter RendererComparisonBenchmarks
//

#if os(macOS)
import Testing
import Foundation
import AppKit
import WebKit
@testable import MarkDownRange

@Suite(.tags(.benchmark), .enabled(if: BenchmarkGate.enabled), .serialized)
struct RendererComparisonBenchmarks {
	private static let width: CGFloat = 800
	private static let inset: CGFloat = 24

	@MainActor
	private func textViewMs(_ markdown: String) async -> (parse: Double, build: Double, layout: Double) {
		let p0 = CFAbsoluteTimeGetCurrent()
		let blocks = MarkdownBlockParser.parse(markdown)
		let parseMs = (CFAbsoluteTimeGetCurrent() - p0) * 1000
		let b0 = CFAbsoluteTimeGetCurrent()
		let attributed = await MarkdownAttributedStringBuilder.build(
			blocks: blocks, theme: .default, fontSize: 16, availableWidth: Self.width - Self.inset * 2)
		let buildMs = (CFAbsoluteTimeGetCurrent() - b0) * 1000

		let frame = NSRect(x: 0, y: 0, width: Self.width, height: 800)
		let textView = NSTextView(usingTextLayoutManager: true)
		textView.frame = frame
		textView.textContainerInset = NSSize(width: Self.inset, height: 0)
		textView.textContainer?.widthTracksTextView = true
		textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
		let scrollView = NSScrollView(frame: frame)
		scrollView.documentView = textView
		let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
		window.contentView = scrollView
		textView.textStorage?.setAttributedString(attributed)
		var layoutMs = 0.0
		if let lm = textView.textLayoutManager {
			let l0 = CFAbsoluteTimeGetCurrent()
			lm.ensureLayout(for: lm.documentRange)
			layoutMs = (CFAbsoluteTimeGetCurrent() - l0) * 1000
		}
		return (parseMs, buildMs, layoutMs)
	}

	@MainActor
	private func webViewMs(_ markdown: String) async -> (html: Double, load: Double, kb: Int) {
		let h0 = CFAbsoluteTimeGetCurrent()
		let html = MarkdownHTMLRenderer.renderDocument(markdown: markdown, theme: .default, fontSize: 16)
		let htmlMs = (CFAbsoluteTimeGetCurrent() - h0) * 1000

		let frame = NSRect(x: 0, y: 0, width: Self.width, height: 800)
		let webView = WKWebView(frame: frame)
		let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
		window.contentView = webView
		let waiter = NavWaiter()
		webView.navigationDelegate = waiter
		let l0 = CFAbsoluteTimeGetCurrent()
		webView.loadHTMLString(html, baseURL: nil)
		await waiter.wait()
		let loadMs = (CFAbsoluteTimeGetCurrent() - l0) * 1000
		return (htmlMs, loadMs, html.utf8.count / 1024)
	}

	@Test @MainActor func compare() async {
		print("\n— NSTextView vs WKWebView: source → displayed (ms) —")
		_ = await webViewMs("warm up the WebContent process")  // don't charge process spawn to case 1
		let cases: [(String, String)] = [
			("prose/200", RenderFixtures.prose(paragraphs: 200)),
			("lists/300", RenderFixtures.lists(300)),
			("code/80", RenderFixtures.codeBlocks(80)),
			("tables/80", RenderFixtures.tables(80)),
			("callouts/80", RenderFixtures.callouts(80)),
			("mixed/80", RenderFixtures.mixed(sections: 80)),
			("mixed/200", RenderFixtures.mixed(sections: 200)),
		]
		for (label, markdown) in cases {
			let tv = await textViewMs(markdown)
			let wv = await webViewMs(markdown)
			report(label, tv: tv, wv: wv)
		}
		let samples = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent().deletingLastPathComponent()
			.deletingLastPathComponent().deletingLastPathComponent()
			.appendingPathComponent("Misc/sample_markdowns")
		for name in ["public-apis__public-apis__README.md", "vsouza__awesome-ios__README.md"] {
			guard let text = try? String(contentsOf: samples.appendingPathComponent(name), encoding: .utf8) else { continue }
			let tv = await textViewMs(text)
			let wv = await webViewMs(text)
			report(String(name.prefix(16)), tv: tv, wv: wv)
		}
	}

	private func report(_ label: String, tv: (parse: Double, build: Double, layout: Double), wv: (html: Double, load: Double, kb: Int)) {
		func f(_ v: Double) -> String { String(format: "%7.1f", v) }
		// Both totals include parse (the webview's `html` = renderDocument, which
		// parses internally; the NSTextView side adds parse explicitly).
		let tvTotal = tv.parse + tv.build + tv.layout
		let wvTotal = wv.html + wv.load
		let winner = tvTotal < wvTotal ? "NSTextView" : "WebView"
		let ratio = String(format: "%.1f×", max(tvTotal, wvTotal) / max(0.1, min(tvTotal, wvTotal)))
		let head = label.padding(toLength: 20, withPad: " ", startingAt: 0)
		print("\(head) | NSTextView parse \(f(tv.parse)) build \(f(tv.build)) layout \(f(tv.layout)) = \(f(tvTotal)) | "
			+ "WebView html(+parse) \(f(wv.html)) load \(f(wv.load)) = \(f(wvTotal)) | \(winner) by \(ratio)")
	}
}

@MainActor
private final class NavWaiter: NSObject, WKNavigationDelegate {
	private var finished = false
	private var continuation: CheckedContinuation<Void, Never>?

	func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
		finished = true
		continuation?.resume()
		continuation = nil
	}

	func wait() async {
		if finished { return }
		await withCheckedContinuation { c in
			if finished { c.resume() } else { continuation = c }
		}
	}
}
#endif
