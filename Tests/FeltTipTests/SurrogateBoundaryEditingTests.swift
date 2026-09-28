//
//  SurrogateBoundaryEditingTests.swift
//  FeltTipTests
//
//  UTF-16 offsets are the edit bridge's coordinate system, but a caret or
//  splice boundary must never sit between an emoji's surrogate halves.
//

import Foundation
import Testing
@testable import FeltTip

@Suite(.serialized)
@MainActor
struct SurrogateBoundaryEditingTests {
	private func restoreHostCaret(
		_ offset: Int,
		token: Int,
		in harness: CoordinatorBridgeHarness
	) {
		harness.coordinator.parent = MarkdownWebView(
			text: harness.source,
			theme: .default,
			fontSize: 14
		)
		.editable(true)
		.caretTarget(MarkdownCaretTarget(offset: offset, token: token))
		.onSourceEdit { [weak harness] newText, _ in
			harness?.recordExternalEdit(newText)
		}
		harness.coordinator.applyCaretTarget()
		harness.coordinator.load(into: harness.webView)
	}

	@Test
	func splicerRejectsCollapsedAndExtendedRangesThatSplitAnEmoji() {
		let source = "a😀b"
		let collapsed = MarkdownEditSplicer.Edit(
			start: 2,
			end: 2,
			replacement: "X",
			expected: "",
			crossRun: false,
			before: "",
			after: ""
		)
		let extended = MarkdownEditSplicer.Edit(
			start: 1,
			end: 2,
			replacement: "",
			expected: "",
			crossRun: true,
			selected: true,
			before: "",
			after: ""
		)

		for edit in [collapsed, extended] {
			guard case .rejected(let reason) = MarkdownEditSplicer.apply(edit, to: source) else {
				Issue.record("A surrogate-splitting edit was applied")
				continue
			}
			#expect(reason.contains("surrogate pair"))
		}
	}

	@Test
	func hostCaretInsideEmojiSnapsToItsStartAndEditingStaysSynchronized() async throws {
		let source = "a😀b\n\nTail"
		let harness = try await CoordinatorBridgeHarness(source: source)

		// UTF-16 offset 2 is between 😀's high and low surrogate. A stale host
		// caret can request it during undo/mode handoff; the page must snap to
		// offset 1 rather than emit a lone surrogate in the next edit message.
		try await harness.placeCaret(2)
		try await harness.type("X")
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "aX😀b\n\nTail")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
		#expect(try await harness.stampMismatches() == [])

		let tail = (harness.source as NSString).range(of: "Tail").upperBound
		try await harness.type("Q", at: tail)
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == "aX😀b\n\nTailQ")
		#expect(try await harness.stampMismatches() == [])
	}

	@Test(arguments: [
		(source: "ae\u{301}b\n\nTail", requested: 2, expected: "aXe\u{301}b\n\nTail"),
		(source: "a👩‍💻b\n\nTail", requested: 3, expected: "aX👩‍💻b\n\nTail"),
	])
	func hostCaretInsideAComposedCharacterSnapsToItsStart(
		source: String,
		requested: Int,
		expected: String
	) async throws {
		let harness = try await CoordinatorBridgeHarness(source: source)

		restoreHostCaret(requested, token: 1, in: harness)
		try await harness.waitQuiescent()
		try await harness.type("X")
		try await harness.waitForSourceEdits(1)

		#expect(harness.source == expected)
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
		#expect(try await harness.stampMismatches() == [])
	}
}
