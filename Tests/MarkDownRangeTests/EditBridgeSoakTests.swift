//
//  EditBridgeSoakTests.swift
//  MarkDownRangeTests
//
//  Long-running fuzz soak: many more seeds and ops than the CI fuzz suite,
//  run on demand (MDR_SOAK=1 swift test --filter EditBridgeSoakTests). Same
//  invariants — no hard rejection, source↔DOM convergence, honest stamps.
//

import Foundation
import Testing
@testable import MarkDownRange

#if os(macOS)
	import AppKit
#endif

private let editBridgeSoakSeeds: [UInt64] = {
	if let value = ProcessInfo.processInfo.environment["MDR_SOAK_SEED"],
	   let seed = UInt64(value) {
		return [seed]
	}
	return Array(1000..<1040)
}()

private let editBridgeDeletionSoakSeeds: [UInt64] = {
	if let value = ProcessInfo.processInfo.environment["MDR_DELETION_SOAK_SEED"],
	   let seed = UInt64(value) {
		return [seed]
	}
	return Array(2000..<2010)
}()

@Suite(.serialized) @MainActor struct EditBridgeSoakTests {
	@Test(.enabled(if: ProcessInfo.processInfo.environment["MDR_SOAK"] != nil),
	      arguments: editBridgeSoakSeeds)
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
			if ProcessInfo.processInfo.environment["MDR_SOAK_TRACE"] != nil {
				let fragmentStamps = harness.coordinator.lastFragments?
					.compactMap(\.firstStamp).map(String.init).joined(separator: ",") ?? "nil"
				opLog.append(
					"source now \(harness.source.debugDescription); DOM stamps \(try await harness.stamps()); "
					+ "fragment stamps \(fragmentStamps); rev \(harness.coordinator.currentRev)"
				)
			}
			let stepMismatches = try await harness.stampMismatches()
			if !stepMismatches.isEmpty {
				opLog.append("stamp drift after operation: \(stepMismatches.joined(separator: "; "))")
				break
			}
			if harness.coordinator.hardRejections > 0 {
				opLog.append("stopped after first hard rejection")
				break
			}
			if ProcessInfo.processInfo.environment["MDR_SOAK_CHECK_EACH_EDIT"] != nil {
				let live = EditBridgeFuzzTests.normalizedVisibleText(try await harness.domVisibleText())
				let fresh = try await CoordinatorBridgeHarness(source: harness.source)
				let rendered = EditBridgeFuzzTests.normalizedVisibleText(try await fresh.domVisibleText())
				if live != rendered {
					opLog.append(
						"visible divergence after operation; live \(live.debugDescription); "
						+ "rendered \(rendered.debugDescription)"
					)
					break
				}
			}
		}
		try await harness.waitQuiescent()
		try await Task.sleep(for: .milliseconds(300))

		let script = "soak seed \(seed):\n" + opLog.joined(separator: "\n")
			+ "\nincidents:\n" + harness.coordinator.bridgeIncidents.joined(separator: "\n")
		#expect(harness.coordinator.hardRejections == 0, "hard rejections during \(script)")
		#expect(try await harness.stampMismatches() == [], "stamp drift during \(script)")

		// WebKit may legitimately force a recovery resync after rebalancing
		// whitespace around a deletion. The regular fuzz suite intentionally does
		// not constrain that platform/version-dependent count; the soak follows the
		// same contract and instead requires exact final content and honest stamps.
		// Compare laid-out non-empty content lines rather than attributed-run
		// decomposition or raw textContent. A fresh parse can split identical
		// content at different trait boundaries, and HTML deliberately collapses
		// whitespace that a live contentEditable text node may still retain. Empty
		// editable list items and Return-created caret paragraphs are live editor
		// affordances that a fresh static Markdown render intentionally omits, so
		// their blank lines are not part of this convergence oracle.
		let live = EditBridgeFuzzTests.normalizedVisibleText(try await harness.domVisibleText())
		let fresh = try await CoordinatorBridgeHarness(source: harness.source)
		let rendered = EditBridgeFuzzTests.normalizedVisibleText(try await fresh.domVisibleText())
		#expect(
			live == rendered,
			"source and DOM diverged after \(script)\nsource: \(harness.source.debugDescription)\nlive: \(live.debugDescription)\nrendered: \(rendered.debugDescription)"
		)
	}

	#if os(macOS)
		@Test(.enabled(if: ProcessInfo.processInfo.environment["MDR_DELETION_SOAK"] != nil),
		      arguments: editBridgeDeletionSoakSeeds)
		func deletionHeavyScriptsConvergeAfterEveryCommand(seed: UInt64) async throws {
			var rng = SeededRNG(seed: seed)
			let harness = try await CoordinatorBridgeHarness(
				source: EditBridgeFuzzTests.generateDocument(&rng))
			var opLog: [String] = []

			for _ in 0..<60 {
				guard let spot = try await EditBridgeFuzzTests.randomStampedOffset(harness, &rng)
				else { break }
				let sourceBeforeCommand = harness.source
				let roll = Int.random(in: 0..<100, using: &rng)
				switch roll {
				case 0..<25:
					opLog.append("backspace @\(spot)")
					try await harness.batch([
						"window.__mdPlaceCaret(\(spot))",
						"document.execCommand('delete')",
					])
				case 25..<50:
					opLog.append("forward delete @\(spot)")
					try await harness.batch([
						"window.__mdPlaceCaret(\(spot))",
						"document.execCommand('forwardDelete')",
					])
				case 50..<70:
					opLog.append("word backspace @\(spot)")
					try await harness.placeCaret(spot)
					harness.focusWebView()
					harness.webView.perform(NSSelectorFromString("deleteWordBackward:"), with: nil)
				case 70..<90:
					opLog.append("word forward delete @\(spot)")
					try await harness.placeCaret(spot)
					harness.focusWebView()
					harness.webView.perform(NSSelectorFromString("deleteWordForward:"), with: nil)
				default:
					let character = ["a", "é", "🙂", " "].randomElement(using: &rng)!
					opLog.append("restore \(character) @\(spot)")
					try await harness.type(character, at: spot)
				}

				try await Task.sleep(for: .milliseconds(20))
				try await harness.waitQuiescent()
				if harness.coordinator.resyncCount > 0 {
					opLog.append("source before resync: \(sourceBeforeCommand.debugDescription)")
					opLog.append(
						"last resync: \(harness.coordinator.lastResyncReason ?? "unknown")")
					opLog.append(
						"incidents: " + harness.coordinator.bridgeIncidents.joined(separator: "; "))
					break
				}
				let mismatches = try await harness.stampMismatches()
				if !mismatches.isEmpty {
					opLog.append("source before drift: \(sourceBeforeCommand.debugDescription)")
					opLog.append("source after drift: \(harness.source.debugDescription)")
					opLog.append(
						"last rendered: \(harness.coordinator.lastRenderedText?.debugDescription ?? "nil"); "
						+ "exact fragments: \(harness.coordinator.exactFragmentText?.debugDescription ?? "nil")")
					opLog.append(
						"DOM: " + ((try? await harness.evaluate("document.body.innerHTML")) ?? "nil"))
					opLog.append("stamp drift: \(mismatches.joined(separator: "; "))")
					break
				}
				let live = EditBridgeFuzzTests.normalizedVisibleText(
					try await harness.domVisibleText())
				let fresh = try await CoordinatorBridgeHarness(source: harness.source)
				let rendered = EditBridgeFuzzTests.normalizedVisibleText(
					try await fresh.domVisibleText())
				if live != rendered {
					opLog.append("source before divergence: \(sourceBeforeCommand.debugDescription)")
					opLog.append("source after divergence: \(harness.source.debugDescription)")
					opLog.append(
						"DOM: " + ((try? await harness.evaluate("document.body.innerHTML")) ?? "nil"))
					opLog.append(
						"visible divergence; live \(live.debugDescription); "
						+ "rendered \(rendered.debugDescription)")
					break
				}
			}

			let script = "deletion soak seed \(seed):\n" + opLog.joined(separator: "\n")
			#expect(try await harness.stampMismatches() == [], "stamp drift during \(script)")
			let live = EditBridgeFuzzTests.normalizedVisibleText(try await harness.domVisibleText())
			let fresh = try await CoordinatorBridgeHarness(source: harness.source)
			let rendered = EditBridgeFuzzTests.normalizedVisibleText(try await fresh.domVisibleText())
			#expect(live == rendered, "source and DOM diverged after \(script)")
			#expect(harness.coordinator.resyncCount == 0, "resync during \(script)")
			#expect(harness.coordinator.hardRejections == 0, "rejection during \(script)")
		}
	#endif
}
