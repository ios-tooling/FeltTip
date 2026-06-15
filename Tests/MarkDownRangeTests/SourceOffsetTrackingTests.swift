//
//  SourceOffsetTrackingTests.swift
//  MarkDownRangeTests
//
//  Stage 1 of editable styled text: verify that parsing with source-offset
//  tracking stamps each rendered text run with the correct UTF-16 offset into
//  the raw Markdown.
//

import Testing
@testable import MarkDownRange

@Suite struct SourceOffsetTrackingTests {
	private func firstParagraph(_ md: String, track: Bool = true) -> AttributedString? {
		let blocks = MarkdownBlockParser.parse(md, preprocessed: true, trackSourceOffsets: track)
		for block in blocks { if case .paragraph(let content, _, _) = block { return content } }
		return nil
	}

	private func lastParagraph(_ md: String) -> AttributedString? {
		let blocks = MarkdownBlockParser.parse(md, preprocessed: true, trackSourceOffsets: true)
		var found: AttributedString?
		for block in blocks { if case .paragraph(let content, _, _) = block { found = content } }
		return found
	}

	private func offsets(_ attributed: AttributedString) -> [(text: String, offset: Int?)] {
		attributed.runs.map { (String(attributed[$0.range].characters), $0.markdownSourceOffset) }
	}

	@Test func plainTextStartsAtZero() throws {
		let p = try #require(firstParagraph("hello world"))
		#expect(p.runs.first?.markdownSourceOffset == 0)
	}

	@Test func boldRunMapsInsideMarkers() throws {
		// "a **bold** b": a=0 ' '=1 *=2 *=3 b=4 o=5 l=6 d=7 *=8 *=9 ' '=10 b=11
		let runs = offsets(try #require(firstParagraph("a **bold** b")))
		#expect(runs.first(where: { $0.text == "a " })?.offset == 0)
		#expect(runs.first(where: { $0.text == "bold" })?.offset == 4)
		#expect(runs.first(where: { $0.text == " b" })?.offset == 10)
	}

	@Test func headingTextMapsAfterMarker() throws {
		// "## Title": #=0 #=1 ' '=2 T=3
		let blocks = MarkdownBlockParser.parse("## Title", preprocessed: true, trackSourceOffsets: true)
		var heading: AttributedString?
		for block in blocks { if case .heading(_, let content, _) = block { heading = content } }
		#expect(try #require(heading).runs.first?.markdownSourceOffset == 3)
	}

	@Test func offsetAccountsForPrecedingLines() throws {
		// "x\n\nworld": x=0 \n=1 \n=2 world starts at 3
		let p = try #require(lastParagraph("x\n\nworld"))
		#expect(p.runs.first?.markdownSourceOffset == 3)
	}

	@Test func notTrackedByDefault() throws {
		let p = try #require(firstParagraph("hello", track: false))
		#expect(p.runs.first?.markdownSourceOffset == nil)
	}

	#if os(macOS)
	@Test @MainActor func nsAttributedStringCarriesSourceOffset() throws {
		let p = try #require(firstParagraph("a **bold** b"))
		let out = NSMutableAttributedString()
		MarkdownAttributedStringBuilder.appendInline(from: p, to: out, font: .systemFont(ofSize: 13), defaultColor: .black)
		let boldLocation = (out.string as NSString).range(of: "bold").location
		let value = out.attribute(.markdownSourceOffset, at: boldLocation, effectiveRange: nil) as? Int
		#expect(value == 4)
	}
	#endif
}
