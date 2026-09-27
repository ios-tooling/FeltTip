//
//  BlockPatchBenchmarkTests.swift
//  FeltTipTests
//
//  The Phase-5 gate: computing the incremental patch for a one-block edit in
//  a large document must be far cheaper than the full-document parse it
//  replaces (the render of the new fragments dominates; the diff itself must
//  be near-free).
//

import Testing
import Foundation
@testable import FeltTip

@Suite struct BlockPatchBenchmarkTests {
	@Test func oneBlockEditPatchIsCheapInALargeDocument() {
		var doc = ""
		for i in 1...1500 {
			doc += "# Section \(i)\n\nParagraph \(i) with **bold** text and detail.\n\n"
		}
		let old = MarkdownHTMLRenderer.renderBlockFragments(markdown: doc, includeSourceOffsets: true)
		let edited = doc.replacingOccurrences(of: "Paragraph 700 ", with: "Paragraph 700X ")
		let new = MarkdownHTMLRenderer.renderBlockFragments(markdown: edited, includeSourceOffsets: true)

		let start = ContinuousClock.now
		let patch = MarkdownBlockDiff.patch(from: old, to: new)
		let elapsed = ContinuousClock.now - start

		let unwrapped = try! #require(patch)
		#expect(unwrapped.removeCount == 1)
		#expect(unwrapped.html.count == 1)
		#expect(elapsed < .milliseconds(80), "diff took \(elapsed) for a one-block edit")
	}
}
