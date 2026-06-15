//
//  NestedSourceOffsetTests.swift
//  MarkDownRangeTests
//
//  Source offsets must reach text nested inside lists and blockquotes — the
//  inner BlockBuilder used to drop the converter, leaving that text unmapped so
//  styled-text edits landed at the wrong place in the source.
//

import Testing
@testable import MarkDownRange

@Suite struct NestedSourceOffsetTests {
	private func runs(_ blocks: [MarkdownBlock]) -> [(text: String, offset: Int?)] {
		var out: [(String, Int?)] = []
		for block in blocks {
			switch block {
			case .unorderedList(let items, _): for item in items { out += runs(item.blocks) }
			case .orderedList(let items, _, _): for item in items { out += runs(item.blocks) }
			case .blockquote(let children, _): out += runs(children)
			case .paragraph(let content, _, _):
				for run in content.runs { out.append((String(content[run.range].characters), run.markdownSourceOffset)) }
			default: break
			}
		}
		return out
	}

	@Test func listItemTextCarriesOffset() throws {
		// "- alpha\n- beta": "alpha" begins at 2, "beta" at 10.
		let found = runs(MarkdownBlockParser.parse("- alpha\n- beta", preprocessed: true, trackSourceOffsets: true))
		#expect(found.first(where: { $0.text == "alpha" })?.offset == 2)
		#expect(found.first(where: { $0.text == "beta" })?.offset == 10)
	}

	@Test func tabNestedListItemMapsToSource() throws {
		// "- Frameworks:\n\t- Chronicle here" — the tab-nested "Chronicle here"
		// run must point at the real 'C' (UTF-16 index 17), not be left nil.
		let md = "- Frameworks:\n\t- Chronicle here"
		let cIndex = (md as NSString).range(of: "Chronicle").location
		let found = runs(MarkdownBlockParser.parse(md, preprocessed: true, trackSourceOffsets: true))
		#expect(found.first(where: { $0.text == "Chronicle here" })?.offset == cIndex)
	}

	@Test func blockquoteTextCarriesOffset() throws {
		// "> quoted": "quoted" begins at 2.
		let found = runs(MarkdownBlockParser.parse("> quoted", preprocessed: true, trackSourceOffsets: true))
		#expect(found.first(where: { $0.text == "quoted" })?.offset == 2)
	}
}
