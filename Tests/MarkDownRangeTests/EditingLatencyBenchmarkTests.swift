//
//  EditingLatencyBenchmarkTests.swift
//  MarkDownRangeTests
//
//  End-to-end latency gates for editing in a LARGE document, through the real
//  coordinator and live web view. These exist to catch the regression class
//  the user feels as "sluggish typing": anything that makes per-keystroke or
//  per-Enter cost scale with document size again (a full reparse per
//  keystroke, a lost stamp cache, a structural edit falling back to the
//  frozen-timeout resync). Budgets are deliberately generous — they must pass
//  under parallel test load — but far below the failure modes they guard
//  against.
//

#if os(macOS)
import Testing
@testable import MarkDownRange

@Suite(.serialized) @MainActor struct EditingLatencyBenchmarkTests {
	static func largeDocument(blocks: Int) -> String {
		(0..<blocks).map { "Paragraph \($0) with enough text to make a realistically sized block." }
			.joined(separator: "\n\n")
	}

	@Test func typingInALargeDocumentCommitsEachKeystrokeQuickly() async throws {
		let source = Self.largeDocument(blocks: 800)
		let harness = try await CoordinatorBridgeHarness(source: source)
		let caret = (source as NSString).range(of: "Paragraph 400").location + "Paragraph 400".count
		try await harness.placeCaret(caret)

		var latencies: [Duration] = []
		for i in 1...15 {
			let start = ContinuousClock.now
			try await harness.type("x")
			try await harness.waitForSourceEdits(i)
			latencies.append(ContinuousClock.now - start)
		}
		let sorted = latencies.sorted()
		let median = sorted[sorted.count / 2]
		// An accidental full-document re-render per keystroke costs hundreds
		// of milliseconds on an 800-block document; a healthy fast-path
		// keystroke is a JS round-trip plus one splice.
		#expect(median < .milliseconds(100), "median keystroke commit \(median) in an 800-block document")
		#expect(harness.coordinator.resyncCount == 0)
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func enterInALargeDocumentSettlesWellBeforeTheFrozenTimeout() async throws {
		let source = Self.largeDocument(blocks: 800)
		let harness = try await CoordinatorBridgeHarness(source: source)
		let caret = (source as NSString).range(of: "Paragraph 400").location + "Paragraph 400".count

		let start = ContinuousClock.now
		try await harness.batch([
			"window.__mdPlaceCaret(\(caret))",
			"document.execCommand('insertParagraph')",
		])
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		let settle = ContinuousClock.now - start

		// The structural patch must land well inside the page's 2 s frozen
		// deadline: if patching regressed to the safety-net resync (or a full
		// navigation that never unfreezes), settle time crosses it.
		#expect(settle < .milliseconds(1800), "Enter took \(settle) to settle in an 800-block document")
		#expect(harness.coordinator.resyncCount == 0)
		// And typing must work immediately afterwards.
		try await harness.type("Z")
		try await harness.waitForSourceEdits(2)
		#expect(harness.coordinator.hardRejections == 0)
		#expect(try await harness.stampMismatches() == [])
	}
}
#endif
