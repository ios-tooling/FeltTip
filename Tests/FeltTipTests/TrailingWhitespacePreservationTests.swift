//
//  TrailingWhitespacePreservationTests.swift
//  FeltTipTests
//
//  The Markdown AST drops spaces and tabs at the end of a paragraph. The
//  editable (stamped) parse puts them back as a verbatim run so the styled
//  editor can show them and keep the caret after them across a re-render.
//  These pin down exactly what is recovered, where it is stamped, and what
//  must never be recovered (line breaks, closing heading markers, display
//  renders).
//

import Foundation
import Testing
@testable import FeltTip

@Suite struct TrailingWhitespaceConverterTests {
	@Test(arguments: [
		// (source, line, column, expected text, expected offset)
		("Alpha  ", 1, 6, "  ", 5),
		("Alpha\t", 1, 6, "\t", 5),
		("Alpha \t \t", 1, 6, " \t \t", 5),
		("Intro\nAlpha  ", 2, 6, "  ", 11),
		("Alpha  \nNext", 1, 6, "  ", 5),
		("Alpha  \r\nNext", 1, 6, "  ", 5),
		("Alpha\t\r\n", 1, 6, "\t", 5),
	])
	func recoversTheExactHorizontalWhitespace(
		source: String, line: Int, column: Int, text: String, offset: Int
	) throws {
		let found = try #require(SourceOffsetConverter(source).trailingWhitespace(line: line, column: column))
		#expect(found.text == text)
		#expect(found.offset == offset)
		#expect((source as NSString).substring(with: NSRange(location: found.offset, length: (found.text as NSString).length)) == found.text)
	}

	@Test(arguments: [
		("Alpha", 1, 6),          // nothing after the text
		("Alpha\n", 1, 6),        // only a newline: never recovered
		("Alpha\r\n", 1, 6),      // only CRLF
		("Alpha #", 1, 6),        // a closing heading marker is not whitespace
		("Alpha  x", 1, 6),       // whitespace followed by more text
		("Alpha\u{00A0}", 1, 6),  // NBSP is not Markdown horizontal whitespace
		("Alpha  ", 3, 1),        // line out of range
		("Alpha  ", 0, 1),        // line out of range
	])
	func declinesAnythingThatIsNotPureTrailingWhitespace(source: String, line: Int, column: Int) {
		#expect(SourceOffsetConverter(source).trailingWhitespace(line: line, column: column) == nil)
	}

	@Test func columnsAreUTF8BytesAndOffsetsAreUTF16() throws {
		// "Café" is 5 UTF-8 bytes but 4 UTF-16 units; "👩‍💻" is 11 bytes, 5 units.
		let cafe = try #require(SourceOffsetConverter("Café  ").trailingWhitespace(line: 1, column: 6))
		#expect(cafe.text == "  ")
		#expect(cafe.offset == 4)
		let emoji = "Hi 👩‍💻\t"
		let afterEmoji = 3 + "👩‍💻".utf8.count + 1
		let found = try #require(SourceOffsetConverter(emoji).trailingWhitespace(line: 1, column: afterEmoji))
		#expect(found.text == "\t")
		#expect(found.offset == (emoji as NSString).length - 1)
	}

	@Test func baseOffsetShiftsTheRecoveredStamp() throws {
		let found = try #require(SourceOffsetConverter("Alpha  ", baseOffset: 100).trailingWhitespace(line: 1, column: 6))
		#expect(found.offset == 105)
	}
}

@Suite struct TrailingWhitespaceParserTests {
	private struct Run { let text: String; let offset: Int? }

	/// Visible text and runs of every text-bearing block, in document order.
	private func blocks(_ source: String, stamped: Bool = true) -> [(text: String, runs: [Run])] {
		let parsed = MarkdownBlockParser.parse(source, preprocessed: true, trackSourceOffsets: stamped)
		var out: [(String, [Run])] = []
		func walk(_ blocks: [MarkdownBlock]) {
			for block in blocks {
				switch block {
				case .paragraph(let content, _, _), .heading(_, let content, _):
					let runs = content.runs.map { Run(text: $0.text, offset: $0.markdownSourceOffset) }
					out.append((runs.map(\.text).joined(), runs))
				case .unorderedList(let items, _): for item in items { walk(item.blocks) }
				case .orderedList(let items, _, _): for item in items { walk(item.blocks) }
				case .blockquote(let children, _): walk(children)
				default: break
				}
			}
		}
		walk(parsed)
		return out
	}

	/// Every stamped run must be a verbatim slice of the source at its stamp.
	private func expectVerbatim(_ source: String, sourceLocation: SourceLocation = #_sourceLocation) {
		let ns = source as NSString
		for block in blocks(source) {
			for run in block.runs {
				guard let offset = run.offset else { continue }
				let length = (run.text as NSString).length
				guard offset >= 0, offset + length <= ns.length else {
					Issue.record("run \(run.text.debugDescription) stamped out of range at \(offset)", sourceLocation: sourceLocation)
					continue
				}
				#expect(ns.substring(with: NSRange(location: offset, length: length)) == run.text,
					"run \(run.text.debugDescription) is not verbatim at \(offset)", sourceLocation: sourceLocation)
			}
		}
	}

	// MARK: Paragraphs

	@Test(arguments: [
		("Alpha  ", "Alpha  "),
		("Alpha\t", "Alpha\t"),
		("Alpha \t ", "Alpha \t "),
		("Alpha  \n", "Alpha  "),
		("Alpha  \n\nBeta", "Alpha  "),
		("Alpha\t\r\n\r\nBeta", "Alpha\t"),
	])
	func paragraphKeepsItsTrailingWhitespace(source: String, expected: String) {
		#expect(blocks(source).first?.text == expected)
		expectVerbatim(source)
	}

	@Test func trailingWhitespaceIsStampedAtItsSourceOffset() throws {
		let source = "Intro\n\nAlpha \t"
		let paragraph = try #require(blocks(source).last)
		#expect(paragraph.text == "Alpha \t")
		let covered = paragraph.runs.contains { run in
			guard let offset = run.offset else { return false }
			return offset <= 12 && 12 + 2 <= offset + (run.text as NSString).length
		}
		#expect(covered, "the trailing \" \\t\" at 12 is not covered by a stamped run: \(paragraph.runs.map { ($0.text, $0.offset) })")
		expectVerbatim(source)
	}

	@Test func eachParagraphKeepsOnlyItsOwnWhitespace() {
		let found = blocks("One  \n\nTwo\n\nThree\t\n")
		#expect(found.map(\.text) == ["One  ", "Two", "Three\t"])
	}

	@Test func whitespaceBeforeASoftBreakIsNotMovedToTheEnd() {
		// The single trailing space on line 1 is part of the soft break.
		let text = blocks("Alpha \nBeta").first?.text ?? ""
		#expect(text.hasSuffix("Beta"))
		#expect(!text.hasSuffix(" "))
	}

	@Test func aHardBreakIsNotDuplicatedAsTrailingWhitespace() {
		let text = blocks("Alpha  \nBeta").first?.text ?? ""
		#expect(text.hasSuffix("Beta"), "got \(text.debugDescription)")
		let withTrailing = blocks("Alpha  \nBeta  ").first?.text ?? ""
		#expect(withTrailing.hasSuffix("Beta  "), "got \(withTrailing.debugDescription)")
		expectVerbatim("Alpha  \nBeta  ")
	}

	@Test(arguments: [
		"*Alpha*  ",
		"**Alpha**\t",
		"`code`  ",
		"[link](https://example.com)  ",
		"Text with <https://example.com>  ",
		"~~gone~~ \t",
	])
	func whitespaceAfterInlineMarkupIsKept(source: String) {
		let trailing = String(source.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
		let text = blocks(source).first?.text ?? ""
		#expect(text.hasSuffix(trailing), "\(source.debugDescription) rendered \(text.debugDescription)")
		expectVerbatim(source)
	}

	@Test func nonASCIIParagraphStampsTheWhitespaceInUTF16() {
		for source in ["Café  ", "日本語\t", "Hi 👩‍💻 \t"] {
			let trailing = String(source.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
			#expect(blocks(source).first?.text.hasSuffix(trailing) == true, "\(source)")
			expectVerbatim(source)
		}
	}

	// MARK: Other block types

	@Test(arguments: [
		("# Alpha  ", "Alpha  "),
		("## Alpha\t", "Alpha\t"),
		("###### Deep \t", "Deep \t"),
	])
	func atxHeadingKeepsItsTrailingWhitespace(source: String, expected: String) {
		#expect(blocks(source).first?.text == expected)
		expectVerbatim(source)
	}

	@Test func atxClosingSequenceIsNotTreatedAsWhitespace() {
		#expect(blocks("# Alpha #").first?.text == "Alpha")
		#expect(blocks("# Alpha ##   ").first?.text == "Alpha")
		expectVerbatim("# Alpha ##   ")
	}

	@Test func setextHeadingKeepsWhitespaceOnItsTextLine() {
		#expect(blocks("Alpha  \n=====").first?.text == "Alpha  ")
		#expect(blocks("Alpha\t\n-----").first?.text == "Alpha\t")
		expectVerbatim("Alpha  \n=====")
	}

	@Test(arguments: [
		("- Alpha  ", "Alpha  "),
		("1. Alpha\t", "Alpha\t"),
		("- [ ] Task  ", "Task  "),
		("> Quoted  ", "Quoted  "),
		("> - Nested \t", "Nested \t"),
	])
	func containerBlocksKeepTheirTextsTrailingWhitespace(source: String, expected: String) {
		#expect(blocks(source).last?.text.hasSuffix(expected) == true, "got \(blocks(source).map(\.text))")
		expectVerbatim(source)
	}

	@Test func frontmatterBodyStampsAreShiftedPastTheHeader() {
		let source = "---\ntitle: Hello\n---\nAlpha  \n"
		#expect(blocks(source).last?.text == "Alpha  ")
		expectVerbatim(source)
	}

	@Test func fencedCodeIsUnchanged() {
		// Code blocks keep their own content verbatim; nothing is appended.
		let parsed = MarkdownBlockParser.parse("```\nAlpha  \n```", preprocessed: true, trackSourceOffsets: true)
		#expect(blocks("```\nAlpha  \n```").isEmpty)
		#expect(!parsed.isEmpty)
	}

	// MARK: Rendering modes and caching

	@Test func displayRenderDoesNotGainTrailingWhitespace() {
		#expect(blocks("Alpha  ", stamped: false).first?.text == "Alpha")
		#expect(blocks("# Alpha\t", stamped: false).first?.text == "Alpha")
	}

	@Test func paragraphCacheDistinguishesTrailingWhitespace() {
		// The same visible words with and without trailing whitespace, parsed
		// alternately, must never reuse the other's runs.
		for _ in 0..<3 {
			#expect(blocks("Alpha").first?.text == "Alpha")
			#expect(blocks("Alpha  ").first?.text == "Alpha  ")
			#expect(blocks("Alpha\t").first?.text == "Alpha\t")
		}
	}

	@Test func cachedParagraphReStampsItsWhitespaceAtTheNewOffset() {
		// Identical paragraphs at different offsets share a cache entry whose
		// stamps are shifted; the recovered whitespace must shift with them.
		for prefix in ["", "X\n\n", "Longer intro paragraph.\n\n"] {
			let source = prefix + "Alpha  \n\nBeta"
			#expect(blocks(source).dropLast().last?.text == "Alpha  ", "prefix \(prefix.debugDescription)")
			expectVerbatim(source)
		}
	}

	@Test func everyStampStaysVerbatimAcrossAMixedDocument() {
		let source = """
		# Title  \r
		\r
		Intro paragraph with *style* \t\r
		\r
		- one  \r
		- two\t\r
		\r
		> quote  \r
		\r
		Alpha  \r
		Beta  \r
		\r
		Café 👩‍💻 \t\r

		"""
		expectVerbatim(source)
		let texts = blocks(source).map(\.text)
		#expect(texts.first == "Title  ")
		#expect(texts.contains("Café 👩‍💻 \t"), "got \(texts)")
	}
}
