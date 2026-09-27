//
//  MermaidSVGRenderer.swift
//  FeltTip
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

import CoreGraphics
import Foundation
import WebKit
#if os(macOS)
	import AppKit
#else
	import UIKit
#endif

@MainActor
public final class MermaidSVGRenderer {
	private var webView: WKWebView
	private var loader = WebViewLoadWaiter()
	private var initialized = false
	private static let maximumSources = 100
	private static let maximumSourceBytes = 1 * 1024 * 1024
	private static let maximumDimension: CGFloat = 8_192
	private static let maximumPixels: CGFloat = 32 * 1024 * 1024
	private static let javaScriptTimeout: Duration = .seconds(5)

	public init() {
		webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
		webView.navigationDelegate = loader
	}

	/// Renders each distinct mermaid source to an inline SVG string. Sources that
	/// fail to render are omitted from the result (the caller falls back to the
	/// raw code block), so a single malformed diagram can't sink the export.
	public func renderSVGs(for sources: [String], theme: String) async -> [String: String] {
		guard !sources.isEmpty, let engine = MermaidResources.engineJS else { return [:] }
		guard await initialize(engine: engine, theme: theme) else { return [:] }
		var result: [String: String] = [:]
		for source in sources.prefix(Self.maximumSources)
			where result[source] == nil && source.utf8.count <= Self.maximumSourceBytes {
				if let svg = await render(source) { result[source] = svg }
				if !initialized { break }
			}
		return result
	}

	private func initialize(engine: String, theme: String) async -> Bool {
		if initialized { return true }
		let html = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><script>\(engine)</script></head><body></body></html>"
		webView.loadHTMLString(html, baseURL: nil)
		do {
			try await loader.wait()
		} catch {
			resetWebView()
			return false
		}
		let didInitialize: Bool? = await callWithTimeout { [webView] in
			do {
				_ = try await webView.callAsyncJavaScript(
					"mermaid.initialize({ startOnLoad: false, theme: t, securityLevel: 'strict', fontFamily: '-apple-system, BlinkMacSystemFont, \"SF Pro Text\", sans-serif' });",
					arguments: ["t": theme], contentWorld: .page)
				return true
			} catch {
				return false
			}
		}
		guard didInitialize == true else {
			resetWebView()
			return false
		}
		initialized = true
		return true
	}

	private func render(_ source: String) async -> String? {
		let js = "const { svg } = await mermaid.render('mmd-' + Math.floor(Math.random() * 1e9), src); return svg;"
		return await callWithTimeout { [webView] in
			try? await webView.callAsyncJavaScript(
				js, arguments: ["src": source], contentWorld: .page) as? String
		}
	}

	/// Renders each distinct mermaid source to a PNG (`scale`× pixels) plus its
	/// natural point size. Used by the DOCX / rich-text paths, which embed a
	/// native `NSTextAttachment` from the PNG bytes — their `NSAttributedString`
	/// HTML import drops `data:` image URIs and ignores inline SVG, so neither
	/// markup form survives.
	public func renderImages(for sources: [String], theme: String, scale: CGFloat = 2) async -> [String: RenderedDiagram] {
		guard !sources.isEmpty, let engine = MermaidResources.engineJS else { return [:] }
		guard await initialize(engine: engine, theme: theme) else { return [:] }
		var result: [String: RenderedDiagram] = [:]
		for source in sources.prefix(Self.maximumSources)
			where result[source] == nil && source.utf8.count <= Self.maximumSourceBytes {
				if let diagram = await renderImage(source, scale: scale) { result[source] = diagram }
				if !initialized { break }
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
		guard let dims: DiagramDimensions = await callWithTimeout({ [webView] in
			guard let values = try? await webView.callAsyncJavaScript(
				layout, arguments: ["src": source], contentWorld: .page) as? [String: Any],
				  let w = (values["w"] as? NSNumber)?.doubleValue,
				  let h = (values["h"] as? NSNumber)?.doubleValue else { return nil }
			return DiagramDimensions(
				x: (values["x"] as? NSNumber)?.doubleValue ?? 0,
				y: (values["y"] as? NSNumber)?.doubleValue ?? 0,
				width: w,
				height: h
			)
		}) else { return nil }
		let w = dims.width
		let h = dims.height
		guard w.isFinite, w > 0, h.isFinite, h > 0,
			  w <= Self.maximumDimension, h <= Self.maximumDimension,
			  w * h <= Self.maximumPixels else { return nil }
		let x = dims.x
		let y = dims.y

		// Render to PDF — `createPDF` works on a detached, off-screen webview
		// (`takeSnapshot` needs an on-screen window), then rasterize the vector
		// PDF to a crisp PNG at `scale`×.
		webView.frame = CGRect(x: 0, y: 0, width: max(w + x, 1), height: max(h + y, 1))
		try? await Task.sleep(nanoseconds: 50_000_000)  // let the resize lay out
		let pdfConfig = WKPDFConfiguration()
		pdfConfig.rect = CGRect(x: x, y: y, width: w, height: h)
		guard let pdf = try? await webView.pdf(configuration: pdfConfig),
			  let png = Self.rasterize(pdf: pdf, size: CGSize(width: w, height: h), scale: scale) else { return nil }
		// The caller embeds these PNG bytes via an attachment file wrapper (an
		// image-only attachment doesn't serialize to DOCX/RTF) and uses `size`
		// for the attachment bounds, so the `scale`× pixels lay out at the
		// diagram's natural point size.
		return RenderedDiagram(png: png, size: CGSize(width: w, height: h))
	}

	private struct DiagramDimensions: Sendable {
		let x: Double
		let y: Double
		let width: Double
		let height: Double
	}

	private enum TimedResult<Value: Sendable>: Sendable {
		case value(Value?)
		case timedOut
	}

	/// Race WebKit against a hard deadline. A timed-out WebView is discarded:
	/// JavaScript promises cannot be reliably interrupted in place.
	private func callWithTimeout<Value: Sendable>(
		_ operation: @escaping @MainActor @Sendable () async -> Value?
	) async -> Value? {
		let operationTask = Task { @MainActor in await operation() }
		let (stream, continuation) = AsyncStream<TimedResult<Value>>.makeStream()
		let resultObserver = Task {
			continuation.yield(.value(await operationTask.value))
		}
		let timeoutTask = Task {
			try? await Task.sleep(for: Self.javaScriptTimeout)
			guard !Task.isCancelled else { return }
			continuation.yield(.timedOut)
		}
		var iterator = stream.makeAsyncIterator()
		let result = await iterator.next() ?? .timedOut
		continuation.finish()
		resultObserver.cancel()
		timeoutTask.cancel()
		switch result {
		case .value(let value):
			return value
		case .timedOut:
			operationTask.cancel()
			resetWebView()
			return nil
		}
	}

	private func resetWebView() {
		webView.stopLoading()
		webView.navigationDelegate = nil
		loader = WebViewLoadWaiter()
		webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
		webView.navigationDelegate = loader
		initialized = false
	}

	private static func rasterize(pdf: Data, size: CGSize, scale: CGFloat) -> Data? {
		guard scale.isFinite, scale > 0, scale <= 4,
			  size.width.isFinite, size.height.isFinite,
			  size.width <= maximumDimension, size.height <= maximumDimension,
			  size.width * size.height * scale * scale <= maximumPixels else { return nil }
		#if os(macOS)
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
		#else
			// UIImage can't decode PDF data the way NSImage can, so go through
			// CGPDFDocument directly.
			guard size.width > 0, size.height > 0,
				  let provider = CGDataProvider(data: pdf as CFData),
				  let document = CGPDFDocument(provider),
				  let page = document.page(at: 1) else { return nil }
			let format = UIGraphicsImageRendererFormat()
			format.scale = scale
			format.opaque = false
			let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
				let cg = context.cgContext
				// PDF pages are y-up; the UIKit drawing context is y-down.
				cg.translateBy(x: 0, y: size.height)
				cg.scaleBy(x: 1, y: -1)
				let box = page.getBoxRect(.mediaBox)
				if box.width > 0, box.height > 0 {
					cg.scaleBy(x: size.width / box.width, y: size.height / box.height)
				}
				cg.drawPDFPage(page)
			}
			return image.pngData()
		#endif
	}
}

/// A rasterized mermaid diagram: PNG bytes plus the natural point size at which
/// it should lay out.
public struct RenderedDiagram: Sendable {
	public let png: Data
	public let size: CGSize
}
