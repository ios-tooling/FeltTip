//
//  EditBridgeCaretHintTests.swift
//  MarkDownRangeTests
//
//  The caret hint delivered with onSourceEdit: the bridge computes the
//  post-edit caret from the splicer outcome, so a host's undo bookkeeping
//  doesn't have to recover the edit position by diffing old→new text — a
//  diff that is provably ambiguous when the edit repeats the characters
//  around it, and blind when a replacement leaves the text unchanged.
//

import Testing
@testable import MarkDownRange

@Suite(.serialized) @MainActor struct EditBridgeCaretHintTests {
	@Test func plainInsertReportsCaretAfterInsertion() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha\n\nBeta")
		try await harness.type("X", at: 5)
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "AlphaX\n\nBeta")
		#expect(harness.lastCaretHint == 6)
	}

	@Test func repeatedTextInsertReportsTruePositionNotDiffPosition() async throws {
		// Typing "aa" at offset 2 of a run of a's: a text diff normalizes the
		// insert to the end of the run; the DOM stamps know where it landed.
		let harness = try await CoordinatorBridgeHarness(source: "aaaa zz")
		try await harness.type("aa", at: 2)
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "aaaaaa zz")
		#expect(harness.lastCaretHint == 4)
	}

	@Test func backwardDeleteInRepeatedTextReportsDeletionPoint() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "aaaa zz")
		try await harness.batch([
			"window.__mdPlaceCaret(3)",
			"document.execCommand('delete')",
		])
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "aaa zz")
		#expect(harness.lastCaretHint == 2)
	}

	@Test func identicalReplacementStillReportsCaret() async throws {
		// Selecting "aa" inside "aaaa" and typing "aa" leaves the source
		// byte-identical — a diff sees no edit at all — yet the caret moved.
		let harness = try await CoordinatorBridgeHarness(source: "aaaa zz")
		try await harness.batch([
			"window.__mdPlaceCaret(1)",
			"var sel = window.getSelection()",
			"sel.modify('extend', 'forward', 'character')",
			"sel.modify('extend', 'forward', 'character')",
			"document.execCommand('insertText', false, 'aa')",
		])
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "aaaa zz")
		#expect(harness.lastCaretHint == 3)
	}
}
