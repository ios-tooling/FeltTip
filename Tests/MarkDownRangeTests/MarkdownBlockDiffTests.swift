//
//  MarkdownBlockDiffTests.swift
//  MarkDownRangeTests
//

import Testing
@testable import MarkDownRange

@Suite struct MarkdownBlockDiffTests {
	private func fragments(_ markdown: String) -> [MarkdownBlockFragment] {
		MarkdownHTMLRenderer.renderBlockFragments(markdown: markdown, includeSourceOffsets: true)
	}

	@Test func editInsideOneBlockReplacesJustThatBlock() {
		let old = fragments("Alpha\n\nBeta\n\nGamma")
		let new = fragments("Alpha\n\nBetaX\n\nGamma")
		let patch = try! #require(MarkdownBlockDiff.patch(from: old, to: new))
		#expect(patch.start == 1)
		#expect(patch.removeCount == 1)
		#expect(patch.html.count == 1)
		#expect(patch.tailAnchorOffset == 0)
		#expect(patch.tailAnchorStamp == new[2].firstStamp, "the tail anchors on Gamma's fresh stamp")
		#expect(patch.expectedOldCount == old.count)
	}

	@Test func splittingABlockReplacesOneWithTwo() {
		let old = fragments("Alpha\n\nBeta\n\nGamma")
		let new = fragments("Alpha\n\nBe\n\nta\n\nGamma")
		let patch = try! #require(MarkdownBlockDiff.patch(from: old, to: new))
		#expect(patch.start == 1)
		#expect(patch.removeCount == 1)
		#expect(patch.html.count == 2)
		#expect(patch.tailAnchorOffset == 0)
		#expect(patch.tailAnchorStamp == new[3].firstStamp)
	}

	@Test func identicalDocumentsProduceNoPatch() {
		let old = fragments("Alpha\n\nBeta")
		#expect(MarkdownBlockDiff.patch(from: old, to: fragments("Alpha\n\nBeta")) == nil)
	}

	@Test func emptyBaselineForcesFullSwap() {
		#expect(MarkdownBlockDiff.patch(from: [], to: fragments("Alpha")) == nil)
	}

	@Test func wholesaleRewriteForcesFullSwap() {
		let old = fragments("Alpha\n\nBeta\n\nGamma\n\nDelta\n\nEpsilon")
		let new = fragments("One\n\nTwo\n\nThree\n\nFour\n\nFive")
		#expect(MarkdownBlockDiff.patch(from: old, to: new) == nil)
	}

	@Test func offsetShiftAloneMatchesBySignatureNotHTML() {
		// Editing the first block shifts every later stamp; later blocks must
		// still be recognized as unchanged (suffix), not replaced.
		let old = fragments("Alpha\n\n- one\n- two\n\n**Gamma** tail")
		let new = fragments("AlphaXYZ\n\n- one\n- two\n\n**Gamma** tail")
		let patch = try! #require(MarkdownBlockDiff.patch(from: old, to: new))
		#expect(patch.start == 0)
		#expect(patch.removeCount == 1)
		#expect(patch.tailAnchorOffset == 0)
		#expect(patch.tailAnchorStamp == new[1].firstStamp)
	}

	@Test func appendingABlockPatchesAtTheEnd() {
		let old = fragments("Alpha\n\nBeta")
		let new = fragments("Alpha\n\nBeta\n\nGamma")
		let patch = try! #require(MarkdownBlockDiff.patch(from: old, to: new))
		#expect(patch.start == 2)
		#expect(patch.removeCount == 0)
		#expect(patch.html.count == 1)
		#expect(patch.tailAnchorOffset == -1, "an empty tail needs no anchor")
	}
}
