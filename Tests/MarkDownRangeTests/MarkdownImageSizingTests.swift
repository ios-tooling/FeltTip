import CoreGraphics
import Testing
@testable import MarkDownRange

@Suite struct MarkdownImageSizingTests {
	@Test func rasterWidthConstraintDoesNotUpscaleByDefault() {
		let displayedSize = MarkdownImageSizing.displayedSize(
			intrinsic: CGSize(width: 300, height: 150),
			htmlWidth: 600,
			htmlHeight: nil,
			isSVG: false
		)

		#expect(displayedSize == CGSize(width: 300, height: 150))
	}

	@Test func rasterWidthConstraintCanUpscaleWhenRequested() {
		let displayedSize = MarkdownImageSizing.displayedSize(
			intrinsic: CGSize(width: 300, height: 150),
			htmlWidth: 600,
			htmlHeight: nil,
			isSVG: false,
			allowUpscaling: true
		)

		#expect(displayedSize == CGSize(width: 600, height: 300))
	}

	@Test func svgFitsWithinBounds() {
		let displayedSize = MarkdownImageSizing.displayedSize(
			intrinsic: CGSize(width: 800, height: 400),
			htmlWidth: 300,
			htmlHeight: 120,
			isSVG: true
		)

		#expect(displayedSize == CGSize(width: 240, height: 120))
	}

	@Test func popoutThresholdIgnoresSmallImages() {
		#expect(!MarkdownImageSizing.shouldOfferPopout(for: CGSize(width: 180, height: 180)))
		#expect(MarkdownImageSizing.shouldOfferPopout(for: CGSize(width: 320, height: 180)))
	}

	@Test func fitScaleUsesSmallestViewportRatio() {
		let scale = MarkdownImageSizing.fitScale(
			for: CGSize(width: 1200, height: 800),
			in: CGSize(width: 600, height: 300)
		)

		#expect(scale == 0.375)
	}
}
