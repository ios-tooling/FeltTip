//
//  FrontmatterSourceOffsetTests.swift
//  MarkDownRangeTests
//
//  Editable styled text with frontmatter: body offsets must skip past the
//  stripped frontmatter (so edits map onto the full source), and the
//  frontmatter itself must become editable text rather than a read-only card.
//

import Testing
@testable import MarkDownRange

@Suite struct FrontmatterSourceOffsetTests {
	// Source indices: "---\n"=0…3, "title: Hi\n"=4…13, "---\n"=14…17,
	// "# Heading"=18…, so the "Heading" text run begins at 20.
	private let doc = "---\ntitle: Hi\n---\n# Heading"

	private func blocks(track: Bool) -> [MarkdownBlock] {
		MarkdownBlockParser.parse(doc, preprocessed: track, trackSourceOffsets: track)
	}

	@Test func bodyOffsetSkipsFrontmatter() throws {
		// Without the frontmatter shift this would report 2 (the body-relative
		// offset) and an edit would land 18 characters too early in the source.
		let heading = blocks(track: true).compactMap { block -> AttributedString? in
			if case .heading(_, let content, _) = block { return content }
			return nil
		}.first
		#expect(try #require(heading).runs.first?.markdownSourceOffset == 20)
	}

	@Test func frontmatterIsEditableTextWhenTracking() throws {
		let first = try #require(blocks(track: true).first)
		guard case .paragraph(let content, _, _) = first else {
			Issue.record("expected editable frontmatter paragraph, got \(first)")
			return
		}
		#expect(String(content.characters) == "---\ntitle: Hi\n---")
		#expect(content.runs.first?.markdownSourceOffset == 0)
	}

	@Test func frontmatterStaysCardWhenNotTracking() throws {
		let first = try #require(blocks(track: false).first)
		guard case .frontmatter(let pairs, _) = first else {
			Issue.record("expected frontmatter card, got \(first)")
			return
		}
		#expect(pairs.first?.key == "title")
	}
}
