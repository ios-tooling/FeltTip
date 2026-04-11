import Testing
import Foundation
@testable import MarkDownRange

@Suite struct HeadingTests {
	private func parseHeading(_ md: String) -> (level: Int, text: String)? {
		let blocks = MarkdownBlockParser.parse(md)
		guard case .heading(let level, let content, _) = blocks.first else { return nil }
		return (level, String(content.characters))
	}

	@Test func h1() { #expect(parseHeading("# Hello")?.level == 1) }
	@Test func h2() { #expect(parseHeading("## Hello")?.level == 2) }
	@Test func h3() { #expect(parseHeading("### Hello")?.level == 3) }
	@Test func h4() { #expect(parseHeading("#### Hello")?.level == 4) }
	@Test func h5() { #expect(parseHeading("##### Hello")?.level == 5) }
	@Test func h6() { #expect(parseHeading("###### Hello")?.level == 6) }

	@Test func headingText() {
		#expect(parseHeading("## My Title")?.text == "My Title")
	}

	@Test func headingWithInlineFormatting() {
		let result = parseHeading("# Hello **world**")
		#expect(result?.text == "Hello world")
	}

	@Test func headingWithClosingHashes() {
		#expect(parseHeading("## Title ##")?.text == "Title")
	}

	@Test func setextH1() {
		let result = parseHeading("Title\n======")
		#expect(result?.level == 1)
		#expect(result?.text == "Title")
	}

	@Test func setextH2() {
		let result = parseHeading("Title\n------")
		#expect(result?.level == 2)
	}

	@Test func multipleHeadings() {
		let md = "# First\n\n## Second\n\n### Third"
		let blocks = MarkdownBlockParser.parse(md)
		let headings = blocks.compactMap { b -> Int? in
			if case .heading(let level, _, _) = b { return level }
			return nil
		}
		#expect(headings == [1, 2, 3])
	}
}
