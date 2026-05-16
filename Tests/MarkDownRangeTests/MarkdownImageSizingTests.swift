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

	@Test func widthOnlyPlaceholderIsSquareWhenIntrinsicUnknown() {
		// When the HTML specifies only a width and the dimension cache has
		// not landed yet, callers must still get a non-nil hint so a table
		// column reserves the right width instead of collapsing to ~24pt.
		let displayedSize = MarkdownImageSizing.displayedSize(
			intrinsic: nil,
			htmlWidth: 220,
			htmlHeight: nil,
			isSVG: false
		)

		#expect(displayedSize == CGSize(width: 220, height: 220))
	}

	@Test func heightOnlyPlaceholderIsSquareWhenIntrinsicUnknown() {
		let displayedSize = MarkdownImageSizing.displayedSize(
			intrinsic: nil,
			htmlWidth: nil,
			htmlHeight: 180,
			isSVG: false
		)

		#expect(displayedSize == CGSize(width: 180, height: 180))
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
