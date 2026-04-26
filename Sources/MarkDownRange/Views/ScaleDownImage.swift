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

	private var isSVG: Bool { url.isSVGImage }

	@State private var intrinsicSize: CGSize?

	var body: some View {
		if isSVG {
			#if os(macOS)
			let size = svgFrameSize()
			SVGImageView(url: url, maxWidth: size.width, maxHeight: size.height)
				.frame(width: size.width, height: size.height)
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

	/// Treats `htmlWidth` / `htmlHeight` as max bounds and fits the natural
	/// SVG aspect ratio inside them, so a wide-aspect logo with `width="350"
	/// height="70"` doesn't get clipped vertically when its real aspect is taller
	/// than 5:1.
	private func svgFrameSize() -> CGSize {
		let maxW = htmlWidth ?? 400
		let maxH = htmlHeight ?? 200
		guard let intrinsic = intrinsicSize, intrinsic.width > 0, intrinsic.height > 0 else {
			return CGSize(width: maxW, height: maxH)
		}
		let aspect = intrinsic.width / intrinsic.height
		var w = min(maxW, intrinsic.width)
		var h = w / aspect
		if h > maxH {
			h = maxH
			w = h * aspect
		}
		return CGSize(width: w, height: h)
	}

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
		intrinsicSize = SVGDimensionParser.parse(text) ?? CGSize(width: 400, height: 200)
	}
}
