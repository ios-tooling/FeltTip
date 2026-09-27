//
//  MarkdownBlockFragmentTests.swift
//  FeltTipTests
//
//  The fragment/patch contract the styled view's incremental updates rest on:
//  a fragment's signature must ignore pure source-offset shifts, the joined
//  fragments must equal the whole-body render, and the patch must describe a
//  contiguous replacement the page can apply without a full swap.
//

import Foundation
import Testing
@testable import FeltTip

@Suite struct MarkdownBlockFragmentTests {
	private func fragment(_ html: String) -> MarkdownBlockFragment { MarkdownBlockFragment(html: html) }

	// MARK: Signatures

	@Test func signatureRewritesStampsRelativeToTheFirst() {
		let f = fragment("<p><span data-s=\"10\">a</span><span data-s=\"14\">b</span></p>")
		#expect(f.firstStamp == 10)
		#expect(f.signature == "<p><span data-s=\"0\">a</span><span data-s=\"4\">b</span></p>")
	}

	@Test func aPureOffsetShiftLeavesTheSignatureUnchanged() {
		let early = fragment("<p><span data-s=\"10\">a</span><span data-s=\"14\">b</span></p>")
		let shifted = fragment("<p><span data-s=\"27\">a</span><span data-s=\"31\">b</span></p>")
		#expect(early.signature == shifted.signature)
		#expect(early.html != shifted.html)
	}

	@Test func differentRelativeGeometryChangesTheSignature() {
		let a = fragment("<p><span data-s=\"10\">a</span><span data-s=\"14\">b</span></p>")
		let b = fragment("<p><span data-s=\"10\">a</span><span data-s=\"15\">b</span></p>")
		#expect(a.signature != b.signature)
	}

	@Test func anUnstampedFragmentSignsAsItsOwnHTML() {
		let f = fragment("<hr>")
		#expect(f.firstStamp == nil)
		#expect(f.signature == "<hr>")
	}

	@Test func signaturesStayLazyWhenADiffOnlyNeedsTheUnchangedPrefix() throws {
		let before = (0..<200).map { "paragraph \($0)" }.joined(separator: "\n\n")
		let after = before + " edited"
		let old = MarkdownHTMLRenderer.renderBlockFragments(
			markdown: before, includeSourceOffsets: true)
		let new = MarkdownHTMLRenderer.renderBlockFragments(
			markdown: after, includeSourceOffsets: true)

		#expect(old.allSatisfy { !$0.hasCachedSignature })
		#expect(new.allSatisfy { !$0.hasCachedSignature })
		let patch = try #require(MarkdownBlockDiff.patch(from: old, to: new))
		#expect(patch.start == 199)
		// The suffix probe signs only the mismatching final block. The 199-block
		// unchanged prefix never pays the normalization/allocation cost.
		#expect(old.dropLast().allSatisfy { !$0.hasCachedSignature })
		#expect(new.dropLast().allSatisfy { !$0.hasCachedSignature })
		#expect(old.last?.hasCachedSignature == true)
		#expect(new.last?.hasCachedSignature == true)
	}

	@Test func textThatLooksLikeAStampIsNotRewritten() {
		// Only real attributes are stamps; escaped body text must survive.
		let f = fragment("<p><span data-s=\"5\">data-s=\"99\"</span></p>")
		#expect(f.firstStamp == 5)
		#expect(f.signature.contains("data-s=\"99\"") || f.signature.contains("data-s=\"94\""))
	}

	// MARK: Fragments compose into the whole body

	@Test func joinedFragmentsEqualTheWholeBodyRender() throws {
		let markdown = """
			# Title

			Some *emphasis* and `code` and a [link](https://example.com).

			- one
			- two

			> quoted

			| a | b |
			| --- | --- |
			| c | d |

			Final paragraph.
			"""
		for includeOffsets in [true, false] {
			let fragments = MarkdownHTMLRenderer.renderBlockFragments(
				markdown: markdown, includeSourceOffsets: includeOffsets)
			let whole = MarkdownHTMLRenderer.renderBodyFragment(
				markdown: markdown, includeSourceOffsets: includeOffsets)
			#expect(fragments.map(\.html).joined() == whole, "includeSourceOffsets=\(includeOffsets)")
			#expect(fragments.count > 1)
		}
	}

	@Test func stampedFragmentsCarryAscendingFirstStamps() throws {
		let markdown = "alpha\n\nbeta\n\ngamma\n"
		let stamps = MarkdownHTMLRenderer.renderBlockFragments(markdown: markdown, includeSourceOffsets: true)
			.compactMap(\.firstStamp)
		#expect(stamps == stamps.sorted())
		#expect(stamps.count == 3)
	}

	// MARK: Patches

	private func fragments(_ htmls: [String]) -> [MarkdownBlockFragment] { htmls.map { fragment($0) } }

	@Test func insertingABlockRemovesNothing() throws {
		let old = fragments(["<p><span data-s=\"0\">a</span></p>", "<p><span data-s=\"3\">b</span></p>"])
		let new = fragments(["<p><span data-s=\"0\">a</span></p>",
							 "<p><span data-s=\"3\">x</span></p>",
							 "<p><span data-s=\"6\">b</span></p>"])
		let patch = try #require(MarkdownBlockDiff.patch(from: old, to: new))
		#expect(patch.start == 1)
		#expect(patch.removeCount == 0)
		#expect(patch.html.count == 1)
		#expect(patch.tailAnchorOffset == 0)
		#expect(patch.tailAnchorStamp == 6)
		#expect(patch.expectedOldCount == 2)
	}

	@Test func deletingAMiddleBlockInsertsNothing() throws {
		let old = fragments(["<p><span data-s=\"0\">a</span></p>",
							 "<p><span data-s=\"3\">b</span></p>",
							 "<p><span data-s=\"6\">c</span></p>"])
		let new = fragments(["<p><span data-s=\"0\">a</span></p>", "<p><span data-s=\"3\">c</span></p>"])
		let patch = try #require(MarkdownBlockDiff.patch(from: old, to: new))
		#expect(patch.start == 1)
		// Only the deleted block is removed; the surviving tail keeps its DOM
		// and just gets its stamps shifted to the anchor the host computed.
		#expect(patch.removeCount == 1)
		#expect(patch.html.isEmpty)
		#expect(patch.tailAnchorOffset == 0)
		#expect(patch.tailAnchorStamp == 3)
	}

	@Test func aTailWithoutStampsReportsNoAnchor() throws {
		let old = fragments(["<p><span data-s=\"0\">a</span></p>", "<hr>"])
		let new = fragments(["<p><span data-s=\"0\">ax</span></p>", "<hr>"])
		let patch = try #require(MarkdownBlockDiff.patch(from: old, to: new))
		#expect(patch.tailAnchorOffset == -1)
	}

	@Test func theAnchorSkipsUnstampedTailBlocks() throws {
		let old = fragments(["<p><span data-s=\"0\">a</span></p>", "<hr>", "<p><span data-s=\"5\">b</span></p>"])
		let new = fragments(["<p><span data-s=\"0\">ax</span></p>", "<hr>", "<p><span data-s=\"6\">b</span></p>"])
		let patch = try #require(MarkdownBlockDiff.patch(from: old, to: new))
		#expect(patch.start == 0)
		#expect(patch.tailAnchorOffset == 1)   // the <hr> has no stamp; b does
		#expect(patch.tailAnchorStamp == 6)
	}

	@Test func aChangeSpanningMostOfASmallDocumentFallsBackToAFullSwap() {
		let old = fragments((0..<6).map { "<p><span data-s=\"\($0 * 3)\">\($0)</span></p>" })
		var newHTMLs = (0..<6).map { "<p><span data-s=\"\($0 * 3)\">\($0)</span></p>" }
		for index in 0..<5 { newHTMLs[index] = "<p><span data-s=\"\(index * 3)\">changed\(index)</span></p>" }
		#expect(MarkdownBlockDiff.patch(from: old, to: fragments(newHTMLs)) == nil)
	}

	@Test func theSameSizedChangeInALongDocumentIsWorthPatching() throws {
		let old = fragments((0..<100).map { "<p><span data-s=\"\($0 * 3)\">\($0)</span></p>" })
		var newHTMLs = (0..<100).map { "<p><span data-s=\"\($0 * 3)\">\($0)</span></p>" }
		for index in 10..<15 { newHTMLs[index] = "<p><span data-s=\"\(index * 3)\">changed\(index)</span></p>" }
		let patch = try #require(MarkdownBlockDiff.patch(from: old, to: fragments(newHTMLs)))
		#expect(patch.start == 10)
		#expect(patch.removeCount == 5)
		#expect(patch.expectedOldCount == 100)
	}

	@Test func fourChangedBlocksAlwaysPatchHoweverShortTheDocument() throws {
		let old = fragments((0..<4).map { "<p><span data-s=\"\($0 * 3)\">\($0)</span></p>" })
		let new = fragments((0..<4).map { "<p><span data-s=\"\($0 * 3)\">c\($0)</span></p>" })
		let patch = try #require(MarkdownBlockDiff.patch(from: old, to: new))
		#expect(patch.start == 0)
		#expect(patch.removeCount == 4)
	}

	@Test func realEditsProduceSinglePointPatches() throws {
		// The property the styled view depends on: typing inside one paragraph
		// of a real document patches one block, and the surviving tail is
		// recognized by signature despite every later stamp shifting.
		let before = "# Head\n\nalpha bravo\n\ncharlie delta\n\n- one\n- two\n"
		let after = "# Head\n\nalpha Xbravo\n\ncharlie delta\n\n- one\n- two\n"
		let old = MarkdownHTMLRenderer.renderBlockFragments(markdown: before, includeSourceOffsets: true)
		let new = MarkdownHTMLRenderer.renderBlockFragments(markdown: after, includeSourceOffsets: true)
		let patch = try #require(MarkdownBlockDiff.patch(from: old, to: new))
		#expect(patch.removeCount == 1)
		#expect(patch.html.count == 1)
		#expect(patch.start == 1)
		#expect(patch.expectedOldCount == old.count)
		// The tail anchor addresses a block that really exists after the edit.
		#expect(patch.tailAnchorOffset >= 0)
		#expect(patch.tailAnchorStamp > 0)
	}

	@Test func splittingAParagraphPatchesOneBlockIntoTwo() throws {
		let old = MarkdownHTMLRenderer.renderBlockFragments(
			markdown: "alpha bravo\n\ntail\n", includeSourceOffsets: true)
		let new = MarkdownHTMLRenderer.renderBlockFragments(
			markdown: "alpha\n\nbravo\n\ntail\n", includeSourceOffsets: true)
		let patch = try #require(MarkdownBlockDiff.patch(from: old, to: new))
		#expect(patch.removeCount == 1)
		#expect(patch.html.count == 2)
		#expect(patch.start == 0)
	}
}
