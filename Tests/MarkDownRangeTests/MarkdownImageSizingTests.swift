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

	@Test func svgWithoutAnyDimensionsReturnsNil() {
		// Contract: when an SVG has no HTML-declared dims and no measured
		// intrinsic yet, the sizing helper must report "unknown" so the
		// renderer can substitute a thin badge-sized placeholder instead of
		// reserving a hero-sized frame for every shields.io strip.
		let displayedSize = MarkdownImageSizing.displayedSize(
			intrinsic: nil,
			htmlWidth: nil,
			htmlHeight: nil,
			isSVG: true
		)

		#expect(displayedSize == nil)
	}

	@Test func svgWithHTMLWidthOnlyReservesFullDefaultHeightWhileLoading() {
		// Lock current cold-cache shape: `<img width="318">` reserves the
		// declared width and the 200pt SVG height bound until measureSVG
		// records a real intrinsic. Documented so a future tweak to the
		// width-only branch has to update both this expectation and the
		// callers that depend on the reserved column.
		let displayedSize = MarkdownImageSizing.displayedSize(
			intrinsic: nil,
			htmlWidth: 318,
			htmlHeight: nil,
			isSVG: true
		)

		#expect(displayedSize == CGSize(width: 318, height: 200))
	}

	@Test func svgWidthBoundHonorsAspectOnceMeasured() {
		// Regression guard for the typical badge case after measureSVG lands:
		// htmlWidth alone should not stretch the SVG vertically — the
		// intrinsic aspect ratio wins inside the (width, defaultSVGHeight)
		// bounding box.
		let displayedSize = MarkdownImageSizing.displayedSize(
			intrinsic: CGSize(width: 800, height: 60),
			htmlWidth: 200,
			htmlHeight: nil,
			isSVG: true
		)

		#expect(displayedSize == CGSize(width: 200, height: 15))
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
