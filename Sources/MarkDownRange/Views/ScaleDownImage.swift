//
//  ScaleDownImage.swift
//  MarkDownRange
//

import SwiftUI
import Convey
import JohnnyCache

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
	@State private var loadedImage: PlatformImage?
	/// Flips to `true` when the raster load fails — typically because the
	/// server returned SVG or another format `NSImage` can't decode even
	/// though the URL didn't look like SVG (e.g. badgesize.io endpoints
	/// whose path ends in `.js`). Forces the view through the SVG/WebKit
	/// path, which can render whatever the server actually sends.
	@State private var rasterLoadFailed = false
	/// Flips to `true` after measureSVG actually tried and got no data back —
	/// used to swap the WebKit view for a labeled placeholder so a broken
	/// SVG doesn't render as an empty rectangle.
	@State private var svgLoadFailed = false

	private var effectiveIsSVG: Bool { isSVG || rasterLoadFailed }
	private var didFail: Bool {
		if isSVG && svgLoadFailed { return true }
		if !isSVG && rasterLoadFailed && loadedImage == nil { return true }
		return false
	}

	@MainActor
	init(url: URL, alt: String, htmlWidth: CGFloat? = nil, htmlHeight: CGFloat? = nil, allowUpscaling: Bool = false) {
		self.url = url
		self.alt = alt
		self.htmlWidth = htmlWidth
		self.htmlHeight = htmlHeight
		self.allowUpscaling = allowUpscaling
		// Seed both pieces of state from the process-wide caches so the
		// SwiftUI frame is correct on the very first layout pass and the
		// image is already drawn if previously fetched. Important when the
		// view is hosted as an NSTextAttachment, where the attachment
		// bounds are measured upfront and don't grow when async content
		// loads.
		self._intrinsicSize = State(initialValue: ImageDimensionCache.shared.size(for: url))
		self._loadedImage = State(initialValue: sharedImagesCache[url])
	}

	var body: some View {
		Group {
			if didFail {
				failurePlaceholder
			} else if effectiveIsSVG {
				#if os(macOS)
				let size = displaySize ?? CGSize(width: 400, height: 200)
				SVGImageView(
					url: url,
					maxWidth: size.width,
					maxHeight: size.height,
					onLoadFailure: { Task { @MainActor in svgLoadFailed = true } }
				)
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
		.preference(key: PopoutableImageLoadKey.self, value: loadState)
	}

	@ViewBuilder private var failurePlaceholder: some View {
		ImageFailurePlaceholder(alt: alt, size: placeholderSize)
	}

	/// Hint for the placeholder's box size when we can derive one from the
	/// markdown (e.g. `<img width="400">`); falls back to nil so small badges
	/// just size to their alt text.
	private var placeholderSize: CGSize? {
		if let htmlWidth, let htmlHeight {
			return CGSize(width: htmlWidth, height: htmlHeight)
		}
		if let htmlWidth {
			// No height hint — pick something proportional rather than square.
			// Half-height reads as an "image-shaped" placeholder without
			// gobbling a whole screen for narrow viewports.
			return CGSize(width: htmlWidth, height: max(120, htmlWidth * 0.5))
		}
		// Deliberately ignore `intrinsicSize` here: a failed SVG often falls
		// back to the 400x200 measureSVG default, and reusing that as the
		// placeholder bounds blew small inline images (e.g. CI badges) up to
		// the size of a hero figure. Without a markdown-supplied width, let
		// the placeholder size itself to its alt text.
		return nil
	}

	/// Reported to any enclosing `PopoutableImageView` so it can hide the
	/// zoom button on broken images. `nil` while we're still loading, `true`
	/// once we have something real to draw, `false` if the load gave up.
	private var loadState: Bool? {
		if didFail { return false }
		if rasterLoadFailed && loadedImage == nil && intrinsicSize == nil {
			return false
		}
		if loadedImage != nil { return true }
		if isSVG, intrinsicSize != nil { return true }
		return nil
	}

	private var rasterImage: some View {
		ZStack {
			if let loadedImage {
				#if os(macOS)
				Image(nsImage: loadedImage)
					.resizable()
					.aspectRatio(contentMode: .fit)
				#else
				Image(uiImage: loadedImage)
					.resizable()
					.aspectRatio(contentMode: .fit)
				#endif
			}
		}
		.frame(maxWidth: displaySize?.width ?? 24, maxHeight: displaySize?.height ?? 24)
		.accessibilityLabel(alt.isEmpty ? "Image" : alt)
		.task(id: url) { await loadRaster() }
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

	@MainActor
	private func loadRaster() async {
		guard !isSVG, !rasterLoadFailed, loadedImage == nil else { return }
		do {
			let image = try await sharedImagesCache[async: url]
			guard let image else {
				rasterLoadFailed = true
				return
			}
			loadedImage = image
			if intrinsicSize == nil, image.size.width > 0, image.size.height > 0 {
				intrinsicSize = image.size
				ImageDimensionCache.shared.record(image.size, for: url)
			}
		} catch {
			// NSImage couldn't decode the response (typical when the server
			// returns SVG via a path that doesn't look like SVG). Route the
			// view through the WebKit path instead.
			rasterLoadFailed = true
		}
	}

	private func measureSVG() async {
		guard isSVG, intrinsicSize == nil else { return }
		guard let data = try? await ImageDataLoader.data(from: url) else {
			svgLoadFailed = true
			return
		}
		let text = String(data: data, encoding: .utf8) ?? ""
		let size = SVGDimensionParser.parse(text) ?? CGSize(width: 400, height: 200)
		intrinsicSize = size
		ImageDimensionCache.shared.record(size, for: url)
	}
}
