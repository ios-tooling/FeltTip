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

	init(url: URL, alt: String, htmlWidth: CGFloat? = nil, htmlHeight: CGFloat? = nil) {
		self.url = url
		self.alt = alt
		self.htmlWidth = htmlWidth
		self.htmlHeight = htmlHeight
		// Seed from the process-wide dimension cache so the SwiftUI
		// frame is correct on the very first layout pass — important
		// when the view is hosted as an NSTextAttachment, where the
		// attachment bounds are measured upfront and don't grow when
		// async content loads.
		self._intrinsicSize = State(initialValue: ImageDimensionCache.shared.size(for: url))
	}

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
		let size = img.size
		#else
		guard let img = UIImage(data: data) else { return }
		let size = img.size
		#endif
		intrinsicSize = size
		ImageDimensionCache.shared.record(size, for: url)
	}

	private func measureSVG() async {
		guard isSVG, intrinsicSize == nil else { return }
		guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
		let text = String(data: data, encoding: .utf8) ?? ""
		let size = SVGDimensionParser.parse(text) ?? CGSize(width: 400, height: 200)
		intrinsicSize = size
		ImageDimensionCache.shared.record(size, for: url)
	}
}
