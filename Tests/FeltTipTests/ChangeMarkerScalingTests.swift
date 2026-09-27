//
//  ChangeMarkerScalingTests.swift
//  FeltTipTests
//
//  Change markers on a large tracked document: many diff ranges against many
//  stamped runs. Guards the binary-search scoping in drawChangeMarkers —
//  the old implementation scanned every span (with a forced-layout rect read)
//  per range, which froze scrolling on big documents with long diffs.
//

#if os(macOS)
	import AppKit
#else
	import UIKit
#endif
import Testing
import WebKit
@testable import FeltTip

@Suite(.serialized) @MainActor struct ChangeMarkerScalingTests {
	@Test func twoHundredRangesOnALargeDocumentDrawQuicklyAndCorrectly() async throws {
		let blocks = 800
		let source = (0..<blocks).map { "Paragraph \($0) with enough text to occupy a line." }
			.joined(separator: "\n\n")
		let harness = try await CoordinatorBridgeHarness(source: source)

		// One changed range per fourth paragraph: 200 ranges, spread over the
		// whole document, plus a handful of deletion ticks.
		let ns = source as NSString
		var ranges: [MarkdownLineChanges.ChangedRange] = []
		for i in stride(from: 0, to: blocks, by: 4) {
			let start = ns.range(of: "Paragraph \(i) ").location
			guard start != NSNotFound else { continue }
			ranges.append(.init(range: start..<(start + 12), kind: i.isMultiple(of: 8) ? .added : .modified))
		}
		let deletions = [0, ns.length / 2, ns.length - 1]
		let changes = MarkdownLineChanges(
			changedLines: [:], deletionsAfter: [],
			changedRanges: ranges, deletionOffsets: deletions)
		let json = MarkdownWebView.Coordinator.lineChangesJSON(changes)

		let start = ContinuousClock.now
		try await harness.run("window.__mdSetLineChanges(\(json))")
		try await harness.waitUntil("markers drawn") {
			let count = try await harness.evaluate("String(document.querySelectorAll('.felttip-change-marker').length)")
			return count == String(ranges.count + deletions.count)
		}
		let elapsed = ContinuousClock.now - start

		// The pre-scoping implementation was O(ranges × spans) with a forced
		// layout per span visit — seconds at this size. Scoped lookups plus
		// one coalesced redraw must stay well under a second even on a busy
		// test machine.
		#expect(elapsed < .milliseconds(900), "drawing \(ranges.count) markers took \(elapsed)")

		// A redraw after an in-place keystroke must not corrupt or duplicate.
		try await harness.type("x", at: (ns.range(of: "Paragraph 400 ").location + 10))
		try await harness.waitForSourceEdits(1)
		try await harness.run("window.__mdSetLineChanges(\(json))")
		try await harness.waitUntil("markers redrawn") {
			let count = try await harness.evaluate("String(document.querySelectorAll('.felttip-change-marker').length)")
			return count == String(ranges.count + deletions.count)
		}
	}
}
