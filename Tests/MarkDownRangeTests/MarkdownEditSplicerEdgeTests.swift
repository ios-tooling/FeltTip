//
//  MarkdownEditSplicerEdgeTests.swift
//  MarkDownRangeTests
//
//  The splice/verify function at its edges: document boundaries, degenerate
//  ranges, UTF-16 geometry (astral characters), list-continuation re-indenting,
//  and the message parsing that feeds it. Pure and synchronous — this is where
//  offset arithmetic is cheap to pin down, so the browser-driven suites can
//  concentrate on WebKit's behavior.
//

import Foundation
import Testing
@testable import MarkDownRange

@Suite struct MarkdownEditSplicerEdgeTests {
	private func edit(_ start: Int, _ end: Int, text: String?, expected: String = "",
					  before: String = "", after: String = "", caret: Int? = nil,
					  crossRun: Bool = false, selected: Bool = false,
					  marker: String? = nil, listBreak: Bool = false,
					  blockStartBreak: Bool = false,
					  syntaxStart: [String] = [], syntaxEnd: [String] = []) -> MarkdownEditSplicer.Edit {
		MarkdownEditSplicer.Edit(start: start, end: end, replacement: text, wrapMarker: marker,
								 expected: expected, crossRun: crossRun, selected: selected,
								 before: before, after: after,
								 syntaxStart: syntaxStart, syntaxEnd: syntaxEnd,
								 caret: caret, listBreak: listBreak,
								 blockStartBreak: blockStartBreak)
	}

	private func applied(_ outcome: MarkdownEditSplicer.Outcome) -> (String, NSRange?)? {
		guard case .applied(let text, let selection, _) = outcome else { return nil }
		return (text, selection)
	}

	private func rejection(_ outcome: MarkdownEditSplicer.Outcome) -> String? {
		guard case .rejected(let reason) = outcome else { return nil }
		return reason
	}

	// MARK: Boundaries and degenerate ranges

	@Test func insertionAtOffsetZero() {
		let outcome = MarkdownEditSplicer.apply(edit(0, 0, text: "X", after: "abc"), to: "abc")
		#expect(applied(outcome)?.0 == "Xabc")
	}

	@Test func insertionAtEndOfDocument() {
		let outcome = MarkdownEditSplicer.apply(edit(3, 3, text: "X", before: "abc"), to: "abc")
		#expect(applied(outcome)?.0 == "abcX")
	}

	@Test func insertionIntoAnEmptyDocument() {
		#expect(applied(MarkdownEditSplicer.apply(edit(0, 0, text: "X"), to: ""))?.0 == "X")
	}

	@Test func deletingTheWholeDocument() {
		let outcome = MarkdownEditSplicer.apply(edit(0, 3, text: "", expected: "abc"), to: "abc")
		#expect(applied(outcome)?.0 == "")
	}

	@Test func negativeAndInvertedRangesAreRejected() {
		#expect(rejection(MarkdownEditSplicer.apply(edit(-1, 2, text: "X"), to: "abc")) != nil)
		#expect(rejection(MarkdownEditSplicer.apply(edit(2, 1, text: "X"), to: "abc")) != nil)
		#expect(rejection(MarkdownEditSplicer.apply(edit(2, 9, text: "X"), to: "abc")) != nil)
	}

	@Test func aCollapsedEditWithNoContextStillApplies() {
		// Nothing to verify — the revision gate upstream is what makes this safe.
		#expect(applied(MarkdownEditSplicer.apply(edit(1, 1, text: "X"), to: "abc"))?.0 == "aXbc")
	}

	// MARK: UTF-16 geometry

	@Test func offsetsAfterAnAstralCharacterAreUTF16() {
		let source = "a😀b"                     // a=0, emoji=1..2, b=3
		let outcome = MarkdownEditSplicer.apply(edit(3, 3, text: "X", before: "a😀"), to: source)
		#expect(applied(outcome)?.0 == "a😀Xb")
	}

	@Test func replacingAnAstralCharacterVerifiesAsTwoUnits() {
		let outcome = MarkdownEditSplicer.apply(edit(1, 3, text: "!", expected: "😀"), to: "a😀b")
		#expect(applied(outcome)?.0 == "a!b")
	}

	@Test func splittingASurrogatePairIsRejectedByVerification() {
		// Half an emoji can never match the DOM's view of that run.
		#expect(rejection(MarkdownEditSplicer.apply(edit(1, 2, text: "", expected: "😀"), to: "a😀b")) != nil)
	}

	@Test func nonBreakingSpaceInTheSourceMatchesAPlainSpaceFromTheDOM() {
		let source = "a\u{00A0}b"
		let outcome = MarkdownEditSplicer.apply(edit(3, 3, text: "X", before: "a b"), to: source)
		#expect(applied(outcome)?.0 == "a\u{00A0}bX")
	}

	// MARK: Context verification

	@Test func beforeContextThatRunsPastTheStartIsRejected() {
		#expect(rejection(MarkdownEditSplicer.apply(edit(1, 1, text: "X", before: "zzzz"), to: "abc")) != nil)
	}

	@Test func afterContextThatRunsPastTheEndIsRejected() {
		#expect(rejection(MarkdownEditSplicer.apply(edit(2, 2, text: "X", after: "zzzz"), to: "abc")) != nil)
	}

	@Test func contextOffByOneCharacterIsRejected() {
		let reason = rejection(MarkdownEditSplicer.apply(edit(4, 4, text: "X", before: "abcd"), to: "abXd efg"))
		#expect(reason?.contains("before-context") == true)
	}

	@Test func crossRunDeleteWithASelectionMayRemoveSyntax() {
		// The user selected it, so the hidden "**" going away is intended.
		let outcome = MarkdownEditSplicer.apply(
			edit(2, 10, text: "", expected: "bold", crossRun: true, selected: true), to: "a **bold** b")
		#expect(applied(outcome)?.0 == "a  b")
	}

	@Test func collapsedCrossRunDeleteOfNewlinesApplies() {
		let outcome = MarkdownEditSplicer.apply(
			edit(1, 3, text: "", expected: "", crossRun: true, selected: false), to: "a\n\nb")
		#expect(applied(outcome)?.0 == "ab")
	}

	@Test func collapsedBlockMergePreservesOnlyWhitespaceBeforeTheFirstNewline() {
		let cases: [(source: String, start: Int, end: Int, expected: String, caret: Int)] = [
			("a \n\nb", 1, 4, "a b", 2),
			("a   \n\nb", 1, 6, "a   b", 4),
			("a\t\n\nb", 1, 4, "a\tb", 2),
			("a \t \r\n\r\nb", 1, 8, "a \t b", 4),
			// Whitespace on a separator line is part of the separator, not the
			// preceding content, so it is removed with the line breaks.
			("a\n \t\nb", 1, 5, "ab", 1),
		]

		for item in cases {
			let outcome = MarkdownEditSplicer.apply(
				edit(
					item.start, item.end, text: "", caret: item.start,
					crossRun: true, selected: false),
				to: item.source)
			#expect(applied(outcome)?.0 == item.expected, "source=\(String(reflecting: item.source))")
			#expect(applied(outcome)?.1 == NSRange(location: item.caret, length: 0))
		}
	}

	@Test func selectedWhitespaceDeletionConsumesTheWholeSelection() {
		let source = "a \t \n \n b"
		let outcome = MarkdownEditSplicer.apply(
			edit(1, 8, text: "", caret: 1, crossRun: true, selected: true),
			to: source)
		#expect(applied(outcome)?.0 == "ab")
		#expect(applied(outcome)?.1 == NSRange(location: 1, length: 0))
	}

	@Test func collapsedSingleSpaceDeletionStillDeletesTheSpace() {
		let outcome = MarkdownEditSplicer.apply(
			edit(1, 2, text: "", caret: 1, crossRun: true, selected: false),
			to: "a b")
		#expect(applied(outcome)?.0 == "ab")
		#expect(applied(outcome)?.1 == NSRange(location: 1, length: 0))
	}

	@Test func insertionsAtEveryWhitespaceAndNewlineEdgeAreExact() {
		let source = "a \n\n b"
		let cases: [(offset: Int, expected: String)] = [
			(1, "aX \n\n b"),       // before trailing space
			(2, "a X\n\n b"),       // after trailing space
			(3, "a \nX\n b"),       // between separator newlines
			(4, "a \n\nX b"),       // before next line's leading space
			(5, "a \n\n Xb"),       // after next line's leading space
		]

		for item in cases {
			let outcome = MarkdownEditSplicer.apply(
				edit(item.offset, item.offset, text: "X", caret: item.offset + 1),
				to: source)
			#expect(applied(outcome)?.0 == item.expected, "offset=\(item.offset)")
			#expect(applied(outcome)?.1 == NSRange(location: item.offset + 1, length: 0))
		}
	}

	@Test func deletionsAtEveryWhitespaceAndNewlineEdgeAreExact() {
		let source = "a \n\n b"
		let cases: [(start: Int, end: Int, expected: String)] = [
			(1, 2, "a\n\n b"),       // trailing space only
			(2, 3, "a \n b"),        // first separator newline
			(2, 4, "a  b"),          // complete separator
			(4, 5, "a \n\nb"),       // next line's leading space
		]

		for item in cases {
			let outcome = MarkdownEditSplicer.apply(
				edit(
					item.start, item.end, text: "",
					expected: (source as NSString).substring(
						with: NSRange(location: item.start, length: item.end - item.start)),
					caret: item.start),
				to: source)
			#expect(applied(outcome)?.0 == item.expected, "range=\(item.start)..<\(item.end)")
		}
	}

	@Test func cutConsumesNestedInlineAndLinkSyntax() {
		let source = "[**Alpha**](https://example.com) Tail"
		let outcome = MarkdownEditSplicer.apply(
			edit(
				3, 8, text: "", expected: "Alpha", caret: 3, selected: true,
				syntaxStart: ["strong", "a"], syntaxEnd: ["strong", "a"]),
			to: source)
		#expect(applied(outcome)?.0 == " Tail")
		#expect(applied(outcome)?.1 == NSRange(location: 0, length: 0))
	}

	@Test func pasteConsumesOwnedSyntaxAndRestoresCaretFromExpandedStart() {
		let source = "Before **Alpha** and _Beta_ after"
		let outcome = MarkdownEditSplicer.apply(
			edit(
				9, 26, text: "X", expected: "Alpha and Beta", caret: 10,
				crossRun: true, selected: true,
				syntaxStart: ["strong"], syntaxEnd: ["em"]),
			to: source)
		#expect(applied(outcome)?.0 == "Before X after")
		#expect(applied(outcome)?.1 == NSRange(location: 8, length: 0))
	}

	@Test func cutVerifiesNestedSyntaxIndependentOfNormalizedDOMTagOrder() {
		for item in [
			(source: "~~**Alpha**~~ Tail", start: 4, tags: ["del", "strong"]),
			(source: "<u>**Alpha**</u> Tail", start: 5, tags: ["u", "strong"]),
		] {
			let outcome = MarkdownEditSplicer.apply(
				edit(
					item.start, item.start + 5, text: "", expected: "Alpha",
					caret: item.start, selected: true,
					syntaxStart: item.tags, syntaxEnd: item.tags),
				to: item.source)
			#expect(applied(outcome)?.0 == " Tail", "source=\(item.source)")
		}
	}

	@Test func reorderedSyntaxMetadataStillRejectsAnUnverifiedExtraDelimiter() {
		let outcome = MarkdownEditSplicer.apply(
			edit(
				4, 9, text: "", expected: "Alpha", caret: 4, selected: true,
				syntaxStart: ["del", "strong", "em"],
				syntaxEnd: ["del", "strong", "em"]),
			to: "~~**Alpha**~~ Tail")
		#expect(rejection(outcome)?.contains("syntax boundaries") == true)
	}

	@Test func deeplyRepeatedMalformedSyntaxMetadataRejectsWithoutPermutationExplosion() {
		let authoredDepth = 40
		let source = String(repeating: "<u>", count: authoredDepth)
			+ "Alpha"
			+ String(repeating: "</u>", count: authoredDepth)
		let metadata = Array(repeating: "u", count: authoredDepth + 1)
		let start = authoredDepth * 3
		let outcome = MarkdownEditSplicer.apply(
			edit(
				start, start + 5, text: "", expected: "Alpha",
				caret: start, selected: true,
				syntaxStart: metadata, syntaxEnd: metadata),
			to: source)
		#expect(rejection(outcome)?.contains("syntax boundaries") == true)
	}

	@Test func cutConsumesPaddedVariableLengthCodeDelimiters() {
		let source = "`` `Alpha` `` Tail"
		let outcome = MarkdownEditSplicer.apply(
			edit(
				3, 10, text: "", expected: "`Alpha`", caret: 3, selected: true,
				syntaxStart: ["code"], syntaxEnd: ["code"]),
			to: source)
		#expect(applied(outcome)?.0 == " Tail")
	}

	@Test func mismatchedCutBoundaryMetadataIsRejectedWithoutGuessing() {
		let outcome = MarkdownEditSplicer.apply(
			edit(
				2, 7, text: "", expected: "Alpha", caret: 2, selected: true,
				syntaxStart: ["strong"], syntaxEnd: ["strong"]),
			to: "**Alpha_ Tail")
		#expect(rejection(outcome)?.contains("syntax boundaries") == true)
	}

	// MARK: Wrap toggling

	@Test func boldToggleOffRecognizesUnderscoreTwins() {
		let outcome = MarkdownEditSplicer.apply(
			edit(4, 8, text: nil, expected: "word", marker: "**"), to: "a __word__ b")
		#expect(applied(outcome)?.0 == "a word b")
		#expect(applied(outcome)?.1 == NSRange(location: 2, length: 4))
	}

	@Test func italicToggleOffRecognizesItsUnderscoreTwin() {
		let outcome = MarkdownEditSplicer.apply(
			edit(3, 7, text: nil, expected: "word", marker: "*"), to: "a _word_ b")
		#expect(applied(outcome)?.0 == "a word b")
	}

	@Test func wrapWithOnlyOneSideMarkedWrapsRatherThanUnwrapping() {
		// "**word" isn't a toggle-off candidate; adding markers is correct.
		let outcome = MarkdownEditSplicer.apply(
			edit(4, 8, text: nil, expected: "word", marker: "**"), to: "a **word b")
		#expect(applied(outcome)?.0 == "a ****word** b")
	}

	@Test func wrapNearTheDocumentEdgesDoesNotReadOutOfBounds() {
		let outcome = MarkdownEditSplicer.apply(edit(0, 4, text: nil, expected: "word", marker: "**"), to: "word")
		#expect(applied(outcome)?.0 == "**word**")
		#expect(applied(outcome)?.1 == NSRange(location: 2, length: 4))
	}

	@Test func wrapSelectionSurvivesToggleOnAndOff() {
		let on = MarkdownEditSplicer.apply(edit(2, 6, text: nil, expected: "word", marker: "~~"), to: "a word b")
		let (wrapped, selection) = try! #require(applied(on))
		#expect(wrapped == "a ~~word~~ b")
		let off = MarkdownEditSplicer.apply(
			edit(selection!.location, selection!.upperBound, text: nil, expected: "word", marker: "~~"), to: wrapped)
		#expect(applied(off)?.0 == "a word b")
	}

	// MARK: List continuation re-indenting

	@Test func listBreakInheritsTheItemsIndentation() {
		let source = "- alpha\n  - beta\n"
		let outcome = MarkdownEditSplicer.apply(
			edit(16, 16, text: "\n- ", before: "beta", caret: 19, listBreak: true), to: source)
		let (text, selection) = try! #require(applied(outcome))
		#expect(text == "- alpha\n  - beta\n  - \n")
		// The caret moves past the indentation the splice added.
		#expect(selection == NSRange(location: 21, length: 0))
	}

	@Test func listBreakAtTopLevelAddsNoIndentation() {
		let outcome = MarkdownEditSplicer.apply(
			edit(7, 7, text: "\n- ", before: "alpha", caret: 10, listBreak: true), to: "- alpha\n")
		let (text, selection) = try! #require(applied(outcome))
		#expect(text == "- alpha\n- \n")
		#expect(selection == NSRange(location: 10, length: 0))
	}

	@Test func listBreakInheritsTabIndentation() {
		let source = "- a\n\t- b\n"
		let outcome = MarkdownEditSplicer.apply(
			edit(8, 8, text: "\n- ", caret: 11, listBreak: true), to: source)
		#expect(applied(outcome)?.0 == "- a\n\t- b\n\t- \n")
	}

	@Test func listBreakOnAnOrderedItemKeepsItsIndent() {
		let source = "1. one\n   1. inner\n"
		let outcome = MarkdownEditSplicer.apply(
			edit(18, 18, text: "\n1. ", caret: 22, listBreak: true), to: source)
		#expect(applied(outcome)?.0 == "1. one\n   1. inner\n   1. \n")
	}

	@Test func listBreakContinuesAnUncheckedTaskAsUnchecked() {
		let source = "- [ ] todo\n"
		let outcome = MarkdownEditSplicer.apply(
			edit(10, 10, text: "\n- ", caret: 13, listBreak: true),
			to: source)
		#expect(applied(outcome)?.0 == "- [ ] todo\n- [ ] \n")
		#expect(applied(outcome)?.1 == NSRange(location: 17, length: 0))
	}

	@Test func listBreakContinuesACheckedTaskAsUnchecked() {
		let source = "- [x] done\n"
		let outcome = MarkdownEditSplicer.apply(
			edit(10, 10, text: "\n- ", caret: 13, listBreak: true),
			to: source)
		#expect(applied(outcome)?.0 == "- [x] done\n- [ ] \n")
		#expect(applied(outcome)?.1 == NSRange(location: 17, length: 0))
	}

	@Test func nestedOrderedTaskBreakKeepsKindIndentAndTaskMarker() {
		let source = "1. parent\n   1. [X] child\n"
		let outcome = MarkdownEditSplicer.apply(
			edit(25, 25, text: "\n1. ", caret: 29, listBreak: true),
			to: source)
		#expect(applied(outcome)?.0
			== "1. parent\n   1. [X] child\n   1. [ ] \n")
		#expect(applied(outcome)?.1 == NSRange(location: 36, length: 0))
	}

	@Test func aParagraphBreakIsNeverReIndented() {
		// Only list continuations carry the flag; an indented paragraph break
		// must splice verbatim.
		let source = "  indented text\n"
		let outcome = MarkdownEditSplicer.apply(edit(15, 15, text: "\n\n", caret: 17), to: source)
		#expect(applied(outcome)?.0 == "  indented text\n\n\n")
	}

	@Test func listBreakWhoseReplacementIsNotALineBreakIsLeftAlone() {
		let outcome = MarkdownEditSplicer.apply(
			edit(4, 4, text: "X", caret: 5, listBreak: true), to: "  - item\n")
		#expect(applied(outcome)?.0 == "  - Xitem\n")
	}

	// MARK: Prefixed block starts

	@Test func headingStartBreakMovesHiddenMarkersAndCaretTogether() {
		let source = "> ### **Heading**\n"
		let visible = (source as NSString).range(of: "Heading").location
		let outcome = MarkdownEditSplicer.apply(
			edit(visible, visible, text: "\n\n", after: "Heading",
				 caret: visible + 2, blockStartBreak: true),
			to: source)
		let (text, selection) = try! #require(applied(outcome))
		#expect(text == "\n\n> ### **Heading**\n")
		#expect(selection == NSRange(location: 2, length: 0))
	}

	@Test func prefixedBreakRejectsAFlagThatDoesNotMatchTheSource() {
		let outcome = MarkdownEditSplicer.apply(
			edit(5, 5, text: "\n\n", before: "plain",
				 caret: 7, blockStartBreak: true),
			to: "plain text")
		#expect(rejection(outcome)?.contains("invalid visual block-start break") == true)
	}

	@Test func blockStartBreakRejectsNonParagraphReplacements() {
		let source = "# Heading"
		#expect(rejection(MarkdownEditSplicer.apply(
			edit(2, 2, text: "X", blockStartBreak: true), to: source)) != nil)
	}

	// MARK: Message parsing

	@Test func bodyParsingDefaultsAndOptionals() {
		let minimal = MarkdownEditSplicer.Edit(body: ["start": 1, "end": 2])
		#expect(minimal?.start == 1)
		#expect(minimal?.end == 2)
		#expect(minimal?.replacement == nil)
		#expect(minimal?.wrapMarker == nil)
		#expect(minimal?.expected == "")
		#expect(minimal?.crossRun == false)
		#expect(minimal?.selected == false)
		#expect(minimal?.syntaxStart == [])
		#expect(minimal?.syntaxEnd == [])
		#expect(minimal?.blockPrefixes == [])
		#expect(minimal?.caret == nil)
		#expect(minimal?.listBreak == false)
		#expect(minimal?.blockStartBreak == false)
	}

	@Test func bodyParsingReadsTheListBreakFlag() {
		let parsed = MarkdownEditSplicer.Edit(body: ["start": 3, "end": 3, "text": "\n- ", "caret": 6, "listBreak": true])
		#expect(parsed?.listBreak == true)
		#expect(parsed?.caret == 6)
	}

	@Test func bodyParsingReadsTheBlockStartBreakFlag() {
		let parsed = MarkdownEditSplicer.Edit(body: [
			"start": 2, "end": 2, "text": "\n\n",
			"blockStartBreak": true,
		])
		#expect(parsed?.blockStartBreak == true)
	}

	@Test func bodyParsingReadsCutSyntaxBoundaries() {
		let parsed = MarkdownEditSplicer.Edit(body: [
			"start": 3, "end": 8,
			"syntaxStart": ["strong", "a"],
			"syntaxEnd": ["strong", "a"],
			"blockPrefixes": ["list", "blockquote"],
		])
		#expect(parsed?.syntaxStart == ["strong", "a"])
		#expect(parsed?.syntaxEnd == ["strong", "a"])
		#expect(parsed?.blockPrefixes == ["list", "blockquote"])
	}

	@Test func nonEditMessagesDoNotParse() {
		#expect(MarkdownEditSplicer.Edit(body: ["type": "scroll", "y": 12.0]) == nil)
		#expect(MarkdownEditSplicer.Edit(body: ["start": 1]) == nil)
		#expect(MarkdownEditSplicer.Edit(body: ["start": "1", "end": "2"]) == nil)
	}

	@Test func wrapMarkerOnlyParsesForWrapOperations() {
		#expect(MarkdownEditSplicer.Edit(body: ["start": 0, "end": 1, "op": "wrap", "marker": "**"])?.wrapMarker == "**")
		#expect(MarkdownEditSplicer.Edit(body: ["start": 0, "end": 1, "marker": "**"])?.wrapMarker == nil)
	}
}
