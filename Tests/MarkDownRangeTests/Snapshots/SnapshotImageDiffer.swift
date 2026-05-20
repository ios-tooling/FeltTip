//
//  SnapshotImageDiffer.swift
//  MarkDownRangeTests
//

#if os(macOS)
import AppKit
import CoreGraphics

/// Per-pixel comparison with a per-channel tolerance, returning the fraction
/// of pixels that differ. Tolerant enough to ride out anti-aliasing and font
/// hinting drift without ignoring real layout regressions.
enum SnapshotImageDiffer {
	struct Result {
		let differingPixelFraction: Double
		let sizeMismatch: Bool
	}

	/// `channelTolerance` is the maximum allowed absolute difference (0…255)
	/// per RGB channel before a pixel counts as differing. 5 absorbs
	/// sub-pixel font shifts; 10 starts ignoring meaningful color shifts.
	static func compare(_ a: NSImage, _ b: NSImage, channelTolerance: Int = 6) -> Result {
		guard let aCG = a.cgImage(forProposedRect: nil, context: nil, hints: nil),
			  let bCG = b.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
			return Result(differingPixelFraction: 1, sizeMismatch: true)
		}
		guard aCG.width == bCG.width, aCG.height == bCG.height else {
			return Result(differingPixelFraction: 1, sizeMismatch: true)
		}
		let width = aCG.width
		let height = aCG.height
		guard let aPixels = pixels(from: aCG),
			  let bPixels = pixels(from: bCG),
			  aPixels.count == bPixels.count else {
			return Result(differingPixelFraction: 1, sizeMismatch: false)
		}
		var differing = 0
		let total = width * height
		var i = 0
		while i < aPixels.count {
			let dr = abs(Int(aPixels[i]) - Int(bPixels[i]))
			let dg = abs(Int(aPixels[i + 1]) - Int(bPixels[i + 1]))
			let db = abs(Int(aPixels[i + 2]) - Int(bPixels[i + 2]))
			if dr > channelTolerance || dg > channelTolerance || db > channelTolerance {
				differing += 1
			}
			i += 4
		}
		return Result(
			differingPixelFraction: Double(differing) / Double(total),
			sizeMismatch: false
		)
	}

	/// Renders `cgImage` into a tightly packed RGBA8 buffer so the per-pixel
	/// comparison reads from a known layout regardless of the source PNG's
	/// color space, bit depth, or alpha-premultiplication.
	private static func pixels(from cgImage: CGImage) -> [UInt8]? {
		let width = cgImage.width
		let height = cgImage.height
		let bytesPerRow = width * 4
		let colorSpace = CGColorSpaceCreateDeviceRGB()
		let info = CGImageAlphaInfo.premultipliedLast.rawValue
		var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
		guard let context = buffer.withUnsafeMutableBytes({ raw -> CGContext? in
			guard let base = raw.baseAddress else { return nil }
			return CGContext(
				data: base,
				width: width,
				height: height,
				bitsPerComponent: 8,
				bytesPerRow: bytesPerRow,
				space: colorSpace,
				bitmapInfo: info
			)
		}) else { return nil }
		context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
		return buffer
	}
}
#endif
