//
//  MarkdownImageSizing.swift
//  FeltTip
//

import CoreGraphics

enum MarkdownImageSizing {
	static let minimumPopoutDimension: CGFloat = 220
	static let minimumPopoutArea: CGFloat = 48_000
	private static let defaultSVGWidth: CGFloat = 400
	private static let defaultSVGHeight: CGFloat = 200

	static func displayedSize(
		intrinsic: CGSize?,
		htmlWidth: CGFloat?,
		htmlHeight: CGFloat?,
		isSVG: Bool,
		allowUpscaling: Bool = false
	) -> CGSize? {
		if isSVG {
			return svgDisplayedSize(
				intrinsic: intrinsic,
				htmlWidth: htmlWidth,
				htmlHeight: htmlHeight,
				allowUpscaling: allowUpscaling
			)
		}

		return rasterDisplayedSize(
			intrinsic: intrinsic,
			htmlWidth: htmlWidth,
			htmlHeight: htmlHeight,
			allowUpscaling: allowUpscaling
		)
	}

	static func shouldOfferPopout(for displayedSize: CGSize?) -> Bool {
		guard let displayedSize else { return false }
		let largestDimension = max(displayedSize.width, displayedSize.height)
		let area = displayedSize.width * displayedSize.height
		return largestDimension >= minimumPopoutDimension && area >= minimumPopoutArea
	}

	static func zoomedSize(intrinsic: CGSize, zoom: CGFloat) -> CGSize {
		CGSize(
			width: max(1, intrinsic.width * zoom),
			height: max(1, intrinsic.height * zoom)
		)
	}

	static func fitScale(for contentSize: CGSize, in viewportSize: CGSize) -> CGFloat {
		guard contentSize.width > 0, contentSize.height > 0,
			  viewportSize.width > 0, viewportSize.height > 0 else { return 1 }
		return min(viewportSize.width / contentSize.width, viewportSize.height / contentSize.height)
	}

	private static func rasterDisplayedSize(
		intrinsic: CGSize?,
		htmlWidth: CGFloat?,
		htmlHeight: CGFloat?,
		allowUpscaling: Bool
	) -> CGSize? {
		switch (intrinsic, htmlWidth, htmlHeight) {
		case let (intrinsic?, nil, nil):
			return intrinsic
		case let (intrinsic?, width?, nil):
			let aspect = intrinsic.width / intrinsic.height
			let targetWidth = allowUpscaling ? width : min(width, intrinsic.width)
			return CGSize(width: targetWidth, height: targetWidth / aspect)
		case let (intrinsic?, nil, height?):
			let aspect = intrinsic.width / intrinsic.height
			let targetHeight = allowUpscaling ? height : min(height, intrinsic.height)
			return CGSize(width: targetHeight * aspect, height: targetHeight)
		case let (intrinsic?, width?, height?):
			let maxWidth = allowUpscaling ? width : min(width, intrinsic.width)
			let maxHeight = allowUpscaling ? height : min(height, intrinsic.height)
			return fit(intrinsic, within: CGSize(width: maxWidth, height: maxHeight))
		case (nil, let width?, let height?):
			return CGSize(width: width, height: height)
		case (nil, let width?, nil):
			// Cold cache: assume a square placeholder so the layout reserves a
			// column of roughly the right width. The view will reflow once the
			// intrinsic size lands in the cache.
			return CGSize(width: width, height: width)
		case (nil, nil, let height?):
			return CGSize(width: height, height: height)
		default:
			return nil
		}
	}

	private static func svgDisplayedSize(
		intrinsic: CGSize?,
		htmlWidth: CGFloat?,
		htmlHeight: CGFloat?,
		allowUpscaling: Bool
	) -> CGSize? {
		let maxWidth = htmlWidth ?? defaultSVGWidth
		let maxHeight = htmlHeight ?? defaultSVGHeight

		guard let intrinsic, intrinsic.width > 0, intrinsic.height > 0 else {
			if htmlWidth != nil || htmlHeight != nil {
				return CGSize(width: maxWidth, height: maxHeight)
			}
			return nil
		}

		let boundedWidth = allowUpscaling ? maxWidth : min(maxWidth, intrinsic.width)
		let boundedHeight = allowUpscaling ? maxHeight : min(maxHeight, intrinsic.height)
		return fit(intrinsic, within: CGSize(width: boundedWidth, height: boundedHeight))
	}

	private static func fit(_ size: CGSize, within bounds: CGSize) -> CGSize {
		guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else {
			return .zero
		}

		let widthScale = bounds.width / size.width
		let heightScale = bounds.height / size.height
		let scale = min(widthScale, heightScale)
		return CGSize(width: size.width * scale, height: size.height * scale)
	}
}
