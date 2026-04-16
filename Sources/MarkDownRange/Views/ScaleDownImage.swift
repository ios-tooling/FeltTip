//
//  ScaleDownImage.swift
//  MarkDownRange
//

import SwiftUI
import Convey

/// Renders an image at its intrinsic size (or smaller to fit the container),
/// never scaling up beyond the natural dimensions. SVGs are rendered via
/// WKWebView for full text/path fidelity.
struct ScaleDownImage: View {
	let url: URL
	let alt: String
	var htmlWidth: CGFloat?
	var htmlHeight: CGFloat?

	private var isSVG: Bool {
		url.pathExtension.lowercased() == "svg" || url.absoluteString.contains(".svg")
	}

	@State private var intrinsicSize: CGSize?

	var body: some View {
		if isSVG {
			#if os(macOS)
			SVGImageView(url: url, maxWidth: htmlWidth ?? 400, maxHeight: htmlHeight ?? 200)
				.frame(width: effectiveWidth ?? 120, height: effectiveHeight ?? 20)
				.accessibilityLabel(alt.isEmpty ? "Image" : alt)
				.task(id: url) { await measureSVG() }
			#else
			rasterImage
			#endif
		} else {
			rasterImage
		}
	}

	private var rasterImage: some View {
		CachedURLImage(url: url, contentMode: .fit, placeholder: Image(systemName: "photo"))
			.frame(maxWidth: effectiveWidth ?? 24, maxHeight: effectiveHeight ?? 24)
			.accessibilityLabel(alt.isEmpty ? "Image" : alt)
			.task(id: url) { await measureRaster() }
	}

	private var effectiveWidth: CGFloat? { htmlWidth ?? intrinsicSize?.width }
	private var effectiveHeight: CGFloat? { htmlHeight ?? intrinsicSize?.height }

	private func measureRaster() async {
		guard !isSVG, intrinsicSize == nil else { return }
		guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
		#if os(macOS)
		guard let img = NSImage(data: data) else { return }
		intrinsicSize = img.size
		#else
		guard let img = UIImage(data: data) else { return }
		intrinsicSize = img.size
		#endif
	}

	private func measureSVG() async {
		guard isSVG, intrinsicSize == nil else { return }
		guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
		let text = String(data: data, encoding: .utf8) ?? ""
		intrinsicSize = parseSVGDimensions(text) ?? CGSize(width: 120, height: 20)
	}

	private func parseSVGDimensions(_ svg: String) -> CGSize? {
		let ns = svg as NSString
		let widthPattern = try! NSRegularExpression(pattern: #"<svg[^>]*\bwidth="(\d+)"#, options: .caseInsensitive)
		let heightPattern = try! NSRegularExpression(pattern: #"<svg[^>]*\bheight="(\d+)"#, options: .caseInsensitive)
		guard let wMatch = widthPattern.firstMatch(in: svg, range: NSRange(location: 0, length: ns.length)),
			  let hMatch = heightPattern.firstMatch(in: svg, range: NSRange(location: 0, length: ns.length)),
			  let w = Double(ns.substring(with: wMatch.range(at: 1))),
			  let h = Double(ns.substring(with: hMatch.range(at: 1)))
		else { return nil }
		return CGSize(width: w, height: h)
	}
}
