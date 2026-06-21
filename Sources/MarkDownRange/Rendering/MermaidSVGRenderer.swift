//
//  MermaidSVGRenderer.swift
//  MarkDownRange
//
//  Pre-renders mermaid code blocks using the bundled engine in an offscreen
//  WKWebView, two ways:
//   - `renderSVGs`: standalone inline SVG. HTML / PDF export embed this in place
//     of the raw code — self-contained, no JS engine in the output, renders
//     identically in any viewer. Inline SVG (not a base64 `<img>`) because
//     mermaid labels use `<foreignObject>`, which doesn't render when an SVG is
//     loaded as an image.
//   - `renderImages`: a rasterized PNG (+ natural size). The DOCX / rich-text
//     paths embed it as a native attachment, since `NSAttributedString` carries
//     neither inline SVG nor `data:` images.
//

#if os(macOS)
import AppKit
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

	/// Renders each distinct mermaid source to a PNG (`scale`× pixels) plus its
	/// natural point size. Used by the DOCX / rich-text paths, which embed a
	/// native `NSTextAttachment` from the PNG bytes — their `NSAttributedString`
	/// HTML import drops `data:` image URIs and ignores inline SVG, so neither
	/// markup form survives.
	public func renderImages(for sources: [String], theme: String, scale: CGFloat = 2) async -> [String: RenderedDiagram] {
		guard !sources.isEmpty, let engine = MermaidResources.engineJS else { return [:] }
		await initialize(engine: engine, theme: theme)
		var result: [String: RenderedDiagram] = [:]
		for source in sources where result[source] == nil {
			if let diagram = await renderImage(source, scale: scale) { result[source] = diagram }
		}
		return result
	}

	private func renderImage(_ source: String, scale: CGFloat) async -> RenderedDiagram? {
		// Render into the body at natural (viewBox) size, then snapshot the
		// element's exact rect so the PNG is tightly cropped to the diagram.
		let layout = """
		document.body.style.margin = '0';
		document.body.innerHTML = '';
		const { svg } = await mermaid.render('mmd-' + Math.floor(Math.random() * 1e9), src);
		const div = document.createElement('div');
		div.style.display = 'inline-block';
		div.innerHTML = svg;
		document.body.appendChild(div);
		const el = div.firstElementChild;
		const vb = el.viewBox.baseVal;
		el.setAttribute('width', vb.width);
		el.setAttribute('height', vb.height);
		el.style.maxWidth = 'none';
		const r = el.getBoundingClientRect();
		return { x: r.left, y: r.top, w: Math.ceil(r.width), h: Math.ceil(r.height) };
		"""
		guard let dims = try? await webView.callAsyncJavaScript(layout, arguments: ["src": source], contentWorld: .page) as? [String: Any],
			  let w = (dims["w"] as? NSNumber)?.doubleValue, w > 0,
			  let h = (dims["h"] as? NSNumber)?.doubleValue, h > 0 else { return nil }
		let x = (dims["x"] as? NSNumber)?.doubleValue ?? 0
		let y = (dims["y"] as? NSNumber)?.doubleValue ?? 0

		// Render to PDF — `createPDF` works on a detached, off-screen webview
		// (`takeSnapshot` needs an on-screen window), then rasterize the vector
		// PDF to a crisp PNG at `scale`×.
		webView.frame = NSRect(x: 0, y: 0, width: max(w + x, 1), height: max(h + y, 1))
		try? await Task.sleep(nanoseconds: 50_000_000)  // let the resize lay out
		let pdfConfig = WKPDFConfiguration()
		pdfConfig.rect = NSRect(x: x, y: y, width: w, height: h)
		guard let pdf = try? await webView.pdf(configuration: pdfConfig),
			  let png = Self.rasterize(pdf: pdf, size: CGSize(width: w, height: h), scale: scale) else { return nil }
		// The caller embeds these PNG bytes via an attachment file wrapper (an
		// image-only attachment doesn't serialize to DOCX/RTF) and uses `size`
		// for the attachment bounds, so the `scale`× pixels lay out at the
		// diagram's natural point size.
		return RenderedDiagram(png: png, size: CGSize(width: w, height: h))
	}

	private static func rasterize(pdf: Data, size: CGSize, scale: CGFloat) -> Data? {
		guard let pdfImage = NSImage(data: pdf) else { return nil }
		let pixelsWide = Int((size.width * scale).rounded())
		let pixelsHigh = Int((size.height * scale).rounded())
		guard pixelsWide > 0, pixelsHigh > 0,
			  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
										 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
										 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
		rep.size = size
		NSGraphicsContext.saveGraphicsState()
		NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
		pdfImage.draw(in: NSRect(origin: .zero, size: size))
		NSGraphicsContext.restoreGraphicsState()
		return rep.representation(using: .png, properties: [:])
	}
}

/// A rasterized mermaid diagram: PNG bytes plus the natural point size at which
/// it should lay out.
public struct RenderedDiagram: Sendable {
	public let png: Data
	public let size: CGSize
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
