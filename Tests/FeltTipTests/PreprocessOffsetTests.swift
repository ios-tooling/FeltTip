//
//  PreprocessOffsetTests.swift
//  FeltTipTests
//
//  Editable rendering now preprocesses (so highlight/smart-quotes/emoji render)
//  while tracking a processed→source map, so a run's source offset still points
//  at the original Markdown even when a preprocessor rewrote the text around it.
//

import Testing
@testable import FeltTip

@Suite struct PreprocessOffsetTests {
	private func paragraphRuns(_ md: String) -> [(text: String, offset: Int?)] {
		let blocks = MarkdownBlockParser.parse(md, preprocessed: false, trackSourceOffsets: true)
		var out: [(String, Int?)] = []
		for block in blocks {
			if case .paragraph(let content, _, _) = block {
				for run in content.runs { out.append((run.text, run.markdownSourceOffset)) }
			}
		}
		return out
	}

	@Test func highlightContentMapsThroughPreprocessing() throws {
		// "a ==big== b": the 'big' content sits at source index 4 even though the
		// `==` markers are rewritten by the highlight preprocessor.
		let runs = paragraphRuns("a ==big== b")
		let big = try #require(runs.first(where: { $0.text.contains("big") }))
		#expect(big.offset == 4)
	}

	@Test func plainTextIsUnaffected() throws {
		// No preprocessor construct → identity map → offset 0.
		let runs = paragraphRuns("hello world")
		#expect(runs.first?.offset == 0)
	}
}
