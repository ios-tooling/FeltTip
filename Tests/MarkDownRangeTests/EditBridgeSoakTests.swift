//
//  EditBridgeSoakTests.swift
//  MarkDownRangeTests
//
//  Long-running fuzz soak: many more seeds and ops than the CI fuzz suite,
//  run on demand (MDR_SOAK=1 swift test --filter EditBridgeSoakTests). Same
//  invariants — zero incidents, source↔DOM convergence, honest stamps.
//

import Foundation
import Testing
@testable import MarkDownRange

@Suite(.serialized) @MainActor struct EditBridgeSoakTests {
	@Test(.enabled(if: ProcessInfo.processInfo.environment["MDR_SOAK"] != nil),
	      arguments: Array<UInt64>(1000..<1040))
	func soakRandomEditScriptConverges(seed: UInt64) async throws {
		var rng = SeededRNG(seed: seed)
		let source = EditBridgeFuzzTests.generateDocument(&rng)
		let harness = try await CoordinatorBridgeHarness(source: source)
		var opLog: [String] = []

		for _ in 0..<80 {
			guard let spot = try await EditBridgeFuzzTests.randomStampedOffset(harness, &rng) else { break }
			let roll = Int.random(in: 0..<100, using: &rng)
			if roll < 50 {
				let ch = ["a", "z", "3", " ", "é", "🙂", "\u{00A0}", "\""].randomElement(using: &rng)!
				opLog.append("type \(ch) @\(spot)")
				try await harness.type(ch, at: spot)
			} else if roll < 75 {
				opLog.append("backspace @\(spot)")
				try await harness.batch(["window.__mdPlaceCaret(\(spot))", "document.execCommand('delete')"])
			} else if roll < 88 {
				opLog.append("enter @\(spot)")
				try await harness.batch(["window.__mdPlaceCaret(\(spot))", "document.execCommand('insertParagraph')"])
				try await harness.waitQuiescent()
			} else {
				opLog.append("bold @\(spot)")
				try await harness.batch([
					"window.__mdPlaceCaret(\(spot))",
					"var sel = window.getSelection()",
					"for (var i = 0; i < 4; i++) sel.modify('extend', 'backward', 'character')",
					"document.execCommand('bold')",
				])
				try await harness.waitQuiescent()
			}
			try await Task.sleep(for: .milliseconds(20))
		}
		try await harness.waitQuiescent()
		try await Task.sleep(for: .milliseconds(300))

		let script = "soak seed \(seed):\n" + opLog.joined(separator: "\n")
			+ "\nincidents:\n" + harness.coordinator.bridgeIncidents.joined(separator: "\n")
		#expect(harness.coordinator.hardRejections == 0, "hard rejections during \(script)")
		#expect(harness.coordinator.resyncCount == 0, "resyncs during \(script)")
		#expect(try await harness.stampMismatches() == [], "stamp drift during \(script)")

		let live = EditBridgeFuzzTests.plain(try await harness.domProjectedText())
		let fresh = try await CoordinatorBridgeHarness(source: harness.source)
		let rendered = EditBridgeFuzzTests.plain(try await fresh.domProjectedText())
		#expect(live == rendered, "source and DOM diverged after \(script)")
	}
}
