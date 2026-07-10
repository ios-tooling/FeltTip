import Foundation
import Testing
@testable import MarkDownRange

@Suite struct MarkdownEditSplicerTests {
	private func edit(start: Int, end: Int, text: String? = nil, marker: String? = nil,
					  expected: String = "", crossRun: Bool = false, selected: Bool = false,
					  before: String = "", after: String = "", caret: Int? = nil) -> MarkdownEditSplicer.Edit {
		MarkdownEditSplicer.Edit(start: start, end: end, replacement: text, wrapMarker: marker,
								 expected: expected, crossRun: crossRun, selected: selected,
								 before: before, after: after, caret: caret)
	}

	private func applied(_ outcome: MarkdownEditSplicer.Outcome) -> String? {
		if case .applied(let new, _) = outcome { return new }
		return nil
	}

	@Test func insertionWithMatchingContextApplies() {
		let outcome = MarkdownEditSplicer.apply(edit(start: 5, end: 5, text: "X", before: "Alpha"), to: "Alpha\n\nBeta")
		#expect(applied(outcome) == "AlphaX\n\nBeta")
	}

	@Test func insertionAtStaleOffsetIsRejected() {
		// The corruption the context check exists for: an insertion carries no
		// replaced text to verify, so a stale offset (7 here, where the true
		// position of "Beta" is 8 after an earlier edit) must fail on context.
		let outcome = MarkdownEditSplicer.apply(edit(start: 7, end: 7, text: "Y", after: "Beta"), to: "AlphaX\n\nBeta")
		#expect(applied(outcome) == nil)
	}

	@Test func deletionAppliesAndRejectsOnExpectedMismatch() {
		let source = "Alpha\n\nBeta"
		let good = MarkdownEditSplicer.apply(edit(start: 7, end: 8, text: "", expected: "B", after: "eta"), to: source)
		#expect(applied(good) == "Alpha\n\neta")
		let stale = MarkdownEditSplicer.apply(edit(start: 6, end: 7, text: "", expected: "B", after: "eta"), to: source)
		#expect(applied(stale) == nil)
	}

	@Test func nonBreakingSpacesVerifyAsSpaces() {
		// WebKit swaps ' ' and U+00A0 inside contentEditable at will (1:1 in
		// UTF-16), so both directions of every comparison must tolerate the
		// difference — rejecting it ate every other typed character.
		let source = "a\u{00A0}b c"
		let insert = MarkdownEditSplicer.apply(edit(start: 3, end: 3, text: "X", before: "a b", after: " c"), to: source)
		#expect(applied(insert) == "a\u{00A0}bX c")
		let del = MarkdownEditSplicer.apply(edit(start: 1, end: 2, text: "", expected: " ", before: "a", after: "b"), to: source)
		#expect(applied(del) == "ab c")
	}

	@Test func collapsedCrossRunDeleteOnlyRemovesWhitespace() {
		// A backspace block-merge (no selection) may remove the "\n\n"
		// separator, but never syntax like a closing "**" — that would
		// unbalance the markup around the caret.
		let plain = "Alpha\n\nBeta"
		let merge = MarkdownEditSplicer.apply(edit(start: 5, end: 7, text: "", crossRun: true, before: "Alpha", after: "Beta"), to: plain)
		#expect(applied(merge) == "AlphaBeta")
		let bold = "**Alpha**\n\nBeta"
		let unsafeMerge = MarkdownEditSplicer.apply(edit(start: 7, end: 11, text: "", crossRun: true, before: "Alpha", after: "Beta"), to: bold)
		#expect(applied(unsafeMerge) == nil)
		// The same range is fine when the user actually selected it.
		let selectedDelete = MarkdownEditSplicer.apply(edit(start: 7, end: 11, text: "", crossRun: true, selected: true, before: "Alpha", after: "Beta"), to: bold)
		#expect(applied(selectedDelete) == "**AlphaBeta")
	}

	@Test func crossRunSkipsExpectedButEnforcesContext() {
		// A cross-run delete's DOM range omits the "\n\n" between paragraphs,
		// so expected can't be checked — the surrounding run text still is.
		let source = "Alpha\n\nBeta"
		let merge = MarkdownEditSplicer.apply(edit(start: 5, end: 7, text: "", crossRun: true, before: "Alpha", after: "Beta"), to: source)
		#expect(applied(merge) == "AlphaBeta")
		let drifted = MarkdownEditSplicer.apply(edit(start: 4, end: 6, text: "", crossRun: true, before: "Alpha", after: "Beta"), to: source)
		#expect(applied(drifted) == nil)
	}

	@Test func wrapAppliesMarkersAroundVerifiedRange() {
		let outcome = MarkdownEditSplicer.apply(edit(start: 0, end: 5, marker: "**", expected: "Alpha", after: "\n\nBet"), to: "Alpha\n\nBeta")
		#expect(applied(outcome) == "**Alpha**\n\nBeta")
	}

	@Test func wrapTogglesOffWhenAlreadyWrapped() {
		// ⌘B on already-bold text un-bolds instead of stacking markers, and
		// the caret override lands at the (shrunken) end of the selection.
		let bold = MarkdownEditSplicer.apply(edit(start: 2, end: 7, marker: "**", expected: "Alpha", caret: 11), to: "**Alpha**\n\nBeta")
		guard case .applied(let unwrapped, let selection) = bold else {
			Issue.record("unwrap did not apply")
			return
		}
		#expect(unwrapped == "Alpha\n\nBeta")
		#expect(selection == NSRange(location: 0, length: 5))
		// The underscore twin unwraps too (the raw editor writes _italics_).
		let italic = MarkdownEditSplicer.apply(edit(start: 1, end: 6, marker: "*", expected: "Alpha"), to: "_Alpha_\n\nBeta")
		#expect(applied(italic) == "Alpha\n\nBeta")
	}

	@Test func strikethroughWrapsAndTogglesOff() {
		let wrap = MarkdownEditSplicer.apply(edit(start: 0, end: 5, marker: "~~", expected: "Alpha", after: "\n\nBet"), to: "Alpha\n\nBeta")
		#expect(applied(wrap) == "~~Alpha~~\n\nBeta")
		let unwrap = MarkdownEditSplicer.apply(edit(start: 2, end: 7, marker: "~~", expected: "Alpha"), to: "~~Alpha~~\n\nBeta")
		#expect(applied(unwrap) == "Alpha\n\nBeta")
	}

	@Test func outOfBoundsAndContextPastEdgesAreRejected() {
		#expect(applied(MarkdownEditSplicer.apply(edit(start: 10, end: 12, text: "x"), to: "short")) == nil)
		#expect(applied(MarkdownEditSplicer.apply(edit(start: -1, end: 0, text: "x"), to: "short")) == nil)
		// Context longer than what precedes the edit can't match anything.
		#expect(applied(MarkdownEditSplicer.apply(edit(start: 1, end: 1, text: "x", before: "long-context"), to: "short")) == nil)
	}

	@Test func bodyParsingReadsWrapAndContextFields() {
		let body: [String: Any] = ["op": "wrap", "marker": "**", "start": 2, "end": 4,
								   "expected": "cd", "before": "ab", "after": "ef", "caret": 8, "crossRun": false]
		let edit = MarkdownEditSplicer.Edit(body: body)
		#expect(edit?.wrapMarker == "**")
		#expect(edit?.before == "ab")
		#expect(edit?.after == "ef")
		#expect(edit?.caret == 8)
		#expect(MarkdownEditSplicer.Edit(body: ["type": "scroll"]) == nil)
	}
}
