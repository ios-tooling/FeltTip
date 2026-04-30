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
	var allowUpscaling = false

	private var isSVG: Bool { url.isSVGImage }

	@State private var intrinsicSize: CGSize?

	init(url: URL, alt: String, htmlWidth: CGFloat? = nil, htmlHeight: CGFloat? = nil, allowUpscaling: Bool = false) {
		self.url = url
		self.alt = alt
		self.htmlWidth = htmlWidth
		self.htmlHeight = htmlHeight
		self.allowUpscaling = allowUpscaling
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
			let size = displaySize ?? CGSize(width: 400, height: 200)
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
			.frame(maxWidth: displaySize?.width ?? 24, maxHeight: displaySize?.height ?? 24)
			.accessibilityLabel(alt.isEmpty ? "Image" : alt)
			.task(id: url) { await measureRaster() }
	}

	private var displaySize: CGSize? {
		MarkdownImageSizing.displayedSize(
			intrinsic: intrinsicSize,
			htmlWidth: htmlWidth,
			htmlHeight: htmlHeight,
			isSVG: isSVG,
			allowUpscaling: allowUpscaling
		)
	}

	private func measureRaster() async {
		guard !isSVG, intrinsicSize == nil else { return }
		guard let data = try? await ImageDataLoader.data(from: url) else { return }
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
		guard let data = try? await ImageDataLoader.data(from: url) else { return }
		let text = String(data: data, encoding: .utf8) ?? ""
		let size = SVGDimensionParser.parse(text) ?? CGSize(width: 400, height: 200)
		intrinsicSize = size
		ImageDimensionCache.shared.record(size, for: url)
	}
}
