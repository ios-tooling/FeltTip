import Testing
import Foundation
@testable import FeltTip

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

	@Test func setextH2() {
		let result = parseHeading("Title\n-----")
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

	@Test func markdownHeadingRangesUseUTF16Offsets() throws {
		let source = "🙂 preface\n\n# First\n\ncafé\n\n## Second"
		let headings = MarkdownHeading.parse(from: source)
		let first = try #require(headings.first)
		let second = try #require(headings.last)
		#expect(first.sourceRange.location == (source as NSString).range(of: "# First").location)
		#expect(second.sourceRange.location == (source as NSString).range(of: "## Second").location)
		#expect(MarkdownHeading.characterRange(for: second.id, in: source) == second.sourceRange)
		#expect(MarkdownHeading.heading(
			atCharacterOffset: second.sourceRange.location, in: source)?.id == second.id)
	}

	@Test func markdownHeadingRangesHandleCRLFWithoutDrift() throws {
		let source = "🙂 preface\r\n# First\r\nbody\r\n## Second"
		let headings = MarkdownHeading.parse(from: source)
		let first = try #require(headings.first)
		let second = try #require(headings.last)
		#expect(first.sourceRange == (source as NSString).range(of: "# First"))
		#expect(second.sourceRange == (source as NSString).range(of: "## Second"))
	}

	@Test func parsedHeadingIndexLookupPreservesSourceBoundarySemantics() throws {
		let source = "preface\n# First\nbody 🙂\n## Second\nend"
		let headings = MarkdownHeading.parse(from: source)
		let first = try #require(headings.first)
		let second = try #require(headings.last)

		#expect(MarkdownHeading.heading(
			atCharacterOffset: first.sourceRange.location - 1,
			in: headings) == nil)
		#expect(MarkdownHeading.heading(
			atCharacterOffset: first.sourceRange.location,
			in: headings)?.id == first.id)
		#expect(MarkdownHeading.heading(
			atCharacterOffset: second.sourceRange.location - 1,
			in: headings)?.id == first.id)
		#expect(MarkdownHeading.heading(
			atCharacterOffset: second.sourceRange.location,
			in: headings)?.id == second.id)
	}

	@Test func parsedHeadingIndexSupportsRepeatedDeepScrollLookups() {
		let headings = (0..<100_000).map { index in
			MarkdownHeading(
				id: "\(index)-Heading", level: 2, text: "Heading",
				sourceRange: NSRange(location: index * 100, length: 10))
		}
		let clock = ContinuousClock()
		let elapsed = clock.measure {
			for index in 0..<10_000 {
				let offset = 9_999_999 - index * 7
				_ = MarkdownHeading.heading(
					atCharacterOffset: offset, in: headings)
			}
		}

		#expect(elapsed < .seconds(1), "indexed heading lookups took \(elapsed)")
	}
}
