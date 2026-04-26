import Testing
import Foundation
import CoreGraphics
@testable import MarkDownRange

@Suite struct SVGDimensionTests {
	@Test func parsesExplicitWidthHeight() {
		let svg = #"<svg width="200" height="100" xmlns="http://www.w3.org/2000/svg"></svg>"#
		let size = SVGDimensionParser.parse(svg)
		#expect(size == CGSize(width: 200, height: 100))
	}

	@Test func fallsBackToViewBox() {
		let svg = #"<svg viewBox="0 0 320 240" xmlns="http://www.w3.org/2000/svg"></svg>"#
		let size = SVGDimensionParser.parse(svg)
		#expect(size == CGSize(width: 320, height: 240))
	}

	@Test func explicitDimensionsTakePrecedenceOverViewBox() {
		let svg = #"<svg width="500" height="300" viewBox="0 0 100 100"></svg>"#
		let size = SVGDimensionParser.parse(svg)
		#expect(size == CGSize(width: 500, height: 300))
	}

	@Test func partialExplicitFallsThroughToViewBox() {
		let svg = #"<svg width="500" viewBox="0 0 1000 200"></svg>"#
		let size = SVGDimensionParser.parse(svg)
		// Width is explicit (500); height comes from viewBox (200).
		#expect(size == CGSize(width: 500, height: 200))
	}

	@Test func stripsTrailingUnits() {
		let svg = #"<svg width="200px" height="100pt"></svg>"#
		let size = SVGDimensionParser.parse(svg)
		#expect(size == CGSize(width: 200, height: 100))
	}

	@Test func viewBoxAcceptsCommaSeparators() {
		let svg = #"<svg viewBox="0,0,640,480"></svg>"#
		let size = SVGDimensionParser.parse(svg)
		#expect(size == CGSize(width: 640, height: 480))
	}

	@Test func returnsNilWhenNothingParseable() {
		let svg = "<svg></svg>"
		#expect(SVGDimensionParser.parse(svg) == nil)
	}

	@Test func returnsNilWhenNotSVG() {
		#expect(SVGDimensionParser.parse("<div></div>") == nil)
	}
}

@Suite struct SVGURLDetectionTests {
	@Test func recognizesSvgPathExtension() {
		let url = URL(string: "https://example.com/logo.svg")!
		#expect(url.isSVGImage)
	}

	@Test func recognizesSvgWithQueryString() {
		let url = URL(string: "https://example.com/logo.svg?v=2")!
		#expect(url.isSVGImage)
	}

	@Test func recognizesSvgz() {
		let url = URL(string: "https://example.com/logo.svgz")!
		#expect(url.isSVGImage)
	}

	@Test func rejectsNonSvgUrlContainingDotSvg() {
		// Previously matched naive .contains(".svg") — should now be rejected.
		let url = URL(string: "https://example.com/foo.svg-page/index.html")!
		#expect(!url.isSVGImage)
	}

	@Test func rejectsPlainPNG() {
		let url = URL(string: "https://example.com/photo.png")!
		#expect(!url.isSVGImage)
	}
}
