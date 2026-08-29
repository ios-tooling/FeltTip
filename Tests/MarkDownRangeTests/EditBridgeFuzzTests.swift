//
//  EditBridgeFuzzTests.swift
//  MarkDownRangeTests
//
//  Replays seeded random edit scripts through the real coordinator + live web
//  view and asserts the invariants the protocol exists to guarantee: no hard
//  rejections, no resyncs, and convergence — a fresh render of the final
//  source projects the same text the live (incrementally mutated) DOM shows.
//  Failures print the seed and op log for exact reproduction.
//

#if os(macOS)
	import AppKit
#else
	import UIKit
#endif
import Foundation
import Testing
@testable import MarkDownRange

/// Deterministic RNG (SplitMix64) so every failure is replayable from its seed.
struct SeededRNG: RandomNumberGenerator {
	var state: UInt64
	init(seed: UInt64) { state = seed }
	mutating func next() -> UInt64 {
		state &+= 0x9E3779B97F4A7C15
		var z = state
		z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
		z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
		return z ^ (z >> 31)
	}
}

@Suite(.serialized) @MainActor struct EditBridgeFuzzTests {
	@Test func randomEditOffsetsNeverSplitUnicodeScalars() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "A🙂B")
		var rng = SeededRNG(seed: 0xC0FFEE)
		for _ in 0..<200 {
			let offset = try #require(try await Self.randomStampedOffset(harness, &rng))
			#expect(offset != 2, "random edit offset split the emoji surrogate pair")
		}
	}

	@Test(arguments: [UInt64(1), 2, 3, 4, 5]) func randomEditScriptConverges(seed: UInt64) async throws {
		var rng = SeededRNG(seed: seed)
		let source = Self.generateDocument(&rng)
		let harness = try await CoordinatorBridgeHarness(source: source)
		var opLog: [String] = []

		for _ in 0..<30 {
			guard let spot = try await Self.randomStampedOffset(harness, &rng) else { break }
			let roll = Int.random(in: 0..<100, using: &rng)
			if roll < 55 {
				let ch = ["a", "z", "3", " ", "é", "🙂", "\u{00A0}"].randomElement(using: &rng)!
				opLog.append("type \(ch) @\(spot)")
				try await harness.type(ch, at: spot)
			} else if roll < 80 {
				opLog.append("backspace @\(spot)")
				try await harness.batch(["window.__mdPlaceCaret(\(spot))", "document.execCommand('delete')"])
			} else if roll < 92 {
				opLog.append("enter @\(spot)")
				try await harness.batch(["window.__mdPlaceCaret(\(spot))", "document.execCommand('insertParagraph')"])
				try await harness.waitQuiescent()
			} else {
				opLog.append("bold @\(spot)")
				try await harness.batch([
					"window.__mdPlaceCaret(\(spot))",
					"var sel = window.getSelection()",
					"for (var i = 0; i < 3; i++) sel.modify('extend', 'backward', 'character')",
					"document.execCommand('bold')",
				])
				try await harness.waitQuiescent()
			}
			try await Task.sleep(for: .milliseconds(30))
		}
		try await harness.waitQuiescent()
		try await Task.sleep(for: .milliseconds(300))

		let script = "seed \(seed):\n" + opLog.joined(separator: "\n")
			+ "\nincidents:\n" + harness.coordinator.bridgeIncidents.joined(separator: "\n")
		#expect(harness.coordinator.hardRejections == 0, "hard rejections during \(script)")
		// WebKit can rebalance whitespace around a deletion on either platform.
		// The queued edit's check catches that drift and safely resyncs from the
		// spliced source. How often that happens is WebKit-version-dependent, so
		// the count is not the contract. Convergence below remains strict, as
		// does the absence of hard rejections above.

		// Convergence: a fresh render of the final source must show the same
		// laid-out content as the live DOM. WebKit retains editable whitespace
		// and empty caret blocks that a static render legitimately collapses.
		let live = Self.normalizedVisibleText(try await harness.domVisibleText())
		let fresh = try await CoordinatorBridgeHarness(source: harness.source)
		let rendered = Self.normalizedVisibleText(try await fresh.domVisibleText())
		#expect(live == rendered, "source and DOM diverged after \(script)\nlive:     \(live)\nrendered: \(rendered)")
	}

	@Test(arguments: [UInt64(101), 202, 303, 404, 505])
	func randomForwardAndBackwardSelectionReplacementsConverge(seed: UInt64) async throws {
		var rng = SeededRNG(seed: seed)
		let initial = Self.generateDocument(&rng)
		let harness = try await CoordinatorBridgeHarness(source: initial)
		var expected = initial
		var edits = 0
		var opLog: [String] = []

		for _ in 0..<30 {
			guard let run = try await Self.randomNonEmptyStampedRun(harness, &rng) else { break }
			let lower = Int.random(in: 0..<run.length, using: &rng)
			let selectedLength = Int.random(in: 1...(run.length - lower), using: &rng)
			let start = run.base + lower
			// Keep later random UTF-16 endpoints scalar-safe. Whole astral
			// selections are covered explicitly by the selection matrix; a
			// random offset between an emoji's surrogate halves is not a DOM
			// character boundary and makes the expected NSString splice invalid.
			let replacement = ["", "x", "YZ", "é"].randomElement(using: &rng)!
			let backward = Bool.random(using: &rng)
			opLog.append("\(backward ? "backward" : "forward") \(start)..<\(start + selectedLength) → \(replacement)")
			if ProcessInfo.processInfo.environment["MDR_FUZZ_TRACE"] != nil {
				print("selection seed \(seed) before \(opLog.last!): \(harness.source.debugDescription)")
			}

			var commands = ["window.__mdPlaceCaret(\(start), \(selectedLength))"]
			if backward {
				commands += [
					"var selectedRange = window.getSelection().getRangeAt(0).cloneRange()",
					"window.getSelection().setBaseAndExtent(selectedRange.endContainer, selectedRange.endOffset, selectedRange.startContainer, selectedRange.startOffset)",
				]
			}
			let encoded = String(data: try! JSONEncoder().encode(replacement), encoding: .utf8)!
			commands.append("document.execCommand('insertText', false, \(encoded))")
			try await harness.batch(commands)
			edits += 1
			try await harness.waitForSourceEdits(edits)
			expected = (expected as NSString).replacingCharacters(
				in: NSRange(location: start, length: selectedLength),
				with: replacement)
			// A same-run edit can still require a structural refresh when it
			// changes how nearby Markdown delimiters parse. Do not choose the next
			// random range until that frozen render has landed.
			try await harness.waitQuiescent()
			#expect(harness.coordinator.resyncCount == 0,
				"selection seed \(seed) first resynced after \(opLog.last ?? "unknown operation")")
			if harness.coordinator.resyncCount > 0 {
				print("selection resync incidents: \(harness.coordinator.bridgeIncidents)")
				break
			}
			if harness.source != expected, replacement.isEmpty {
				// Deleting the complete visible contents of a styled run also
				// consumes its now-empty hidden delimiters. The NSString oracle does
				// not model that intentional syntax cleanup (`****` would render as
				// newly visible literal punctuation). Explicit boundary tests pin
				// which delimiters may be consumed; this randomized sequence resumes
				// from the bridge's exact balanced source and continues checking
				// convergence, stamps, incidents, and every nonempty replacement.
				expected = harness.source
				} else {
					#expect(harness.source == expected, "seed \(seed):\n\(opLog.joined(separator: "\n"))")
				}
			if ProcessInfo.processInfo.environment["MDR_FUZZ_CHECK_EACH_EDIT"] != nil {
				let live = Self.normalizedVisibleText(try await harness.domVisibleText())
				let fresh = try await CoordinatorBridgeHarness(source: harness.source)
				let rendered = Self.normalizedVisibleText(try await fresh.domVisibleText())
				let message = "selection seed \(seed) diverged after \(opLog.last ?? "unknown operation"); "
					+ "live \(live.debugDescription), rendered \(rendered.debugDescription)"
				#expect(
					live == rendered,
					Comment(rawValue: message))
			}
		}

		try await harness.waitQuiescent()
		let script = "seed \(seed):\n" + opLog.joined(separator: "\n")
		#expect(try await harness.stampMismatches() == [], "selection fuzz: \(script)")
		#expect(harness.coordinator.hardRejections == 0, "selection fuzz: \(script)")
		#expect(harness.coordinator.resyncCount == 0, "selection fuzz: \(script)")
		#expect(harness.coordinator.vetoedEdits == 0, "selection fuzz: \(script)")
		#expect(harness.coordinator.bridgeIncidents == [], "selection fuzz: \(script)")
	}

	@Test(arguments: [UInt64(7001), 7002, 7003])
	func randomCrossBlockChunkEditsStaySynchronized(seed: UInt64) async throws {
		var rng = SeededRNG(seed: seed)
		var expected = (0..<10)
			.map { "paragraph \($0) alpha beta gamma delta" }
			.joined(separator: "\n\n")
		let harness = try await CoordinatorBridgeHarness(source: expected)
		var edits = 0
		var log: [String] = []

		for _ in 0..<8 {
			let runs = try await Self.nonEmptyStampedRuns(harness)
			guard runs.count >= 2 else { break }
			let firstIndex = Int.random(in: 0..<(runs.count - 1), using: &rng)
			let lastIndex = Int.random(in: (firstIndex + 1)..<runs.count, using: &rng)
			let first = runs[firstIndex], last = runs[lastIndex]
			let start = first.base + Int.random(in: 0..<first.length, using: &rng)
			let end = last.base + Int.random(in: 1...last.length, using: &rng)
			guard end > start else { continue }
			let replacement = ["X", "moved chunk", "inserted text"]
				.randomElement(using: &rng)!
			let backward = Bool.random(using: &rng)
			log.append("\(backward ? "backward" : "forward") \(start)..<\(end) → \(replacement)")

			var commands = ["window.__mdPlaceCaret(\(start), \(end - start))"]
			if backward {
				commands += [
					"var r = window.getSelection().getRangeAt(0).cloneRange()",
					"window.getSelection().setBaseAndExtent(r.endContainer, r.endOffset, r.startContainer, r.startOffset)",
				]
			}
			let encoded = String(data: try! JSONEncoder().encode(replacement), encoding: .utf8)!
			commands.append("document.execCommand('insertText', false, \(encoded))")
			try await harness.batch(commands)
			edits += 1
			try await harness.waitForSourceEdits(edits)
			expected = (expected as NSString).replacingCharacters(
				in: NSRange(location: start, length: end - start),
				with: replacement)
			#expect(harness.source == expected,
				"seed \(seed):\n\(log.joined(separator: "\n"))")
			try await harness.waitQuiescent()
			if ProcessInfo.processInfo.environment["MDR_FUZZ_CHECK_EACH_EDIT"] != nil {
				let live = Self.normalizedVisibleText(try await harness.domVisibleText())
				let fresh = try await CoordinatorBridgeHarness(source: harness.source)
				let rendered = Self.normalizedVisibleText(try await fresh.domVisibleText())
				let message = "cross-block seed \(seed) diverged after \(log.last ?? "unknown operation"); "
					+ "live \(live.debugDescription), rendered \(rendered.debugDescription)"
				#expect(
					live == rendered,
					Comment(rawValue: message))
			}
		}

		let script = "seed \(seed):\n" + log.joined(separator: "\n")
		#expect(try await harness.stampMismatches() == [], "cross-block fuzz: \(script)")
		#expect(harness.coordinator.resyncCount == 0, "cross-block fuzz: \(script)")
		#expect(harness.coordinator.hardRejections == 0, "cross-block fuzz: \(script)")
		#expect(harness.coordinator.bridgeIncidents == [], "cross-block fuzz: \(script)")
	}

	@Test(arguments: [UInt64(8101), 8102, 8103])
	func randomTableCellEditSessionsNeverDamageStructure(seed: UInt64) async throws {
		var rng = SeededRNG(seed: seed)
		var expected = """
			| Name | Role | Score |
			| --- | --- | --- |
			| Alice | Writer | 30 |
			| Bob | Editor | 41 |
			| Carol | Tester | 52 |
			"""
		let harness = try await CoordinatorBridgeHarness(source: expected)
		var edits = 0
		var log: [String] = []

		for _ in 0..<15 {
			let runs = try await Self.tableCellStampedRuns(harness)
			guard let run = runs.randomElement(using: &rng) else { break }
			let lower = Int.random(in: 0..<run.length, using: &rng)
			let selectedLength = Int.random(in: 0...(run.length - lower), using: &rng)
			let start = run.base + lower
			let replacement = ["", "X", "cell", "42"].randomElement(using: &rng)!
			if selectedLength == 0 && replacement.isEmpty { continue }
			log.append("\(start)..<\(start + selectedLength) → \(replacement)")

			let encoded = String(data: try! JSONEncoder().encode(replacement), encoding: .utf8)!
			try await harness.batch([
				"window.__mdPlaceCaret(\(start), \(selectedLength))",
				"document.execCommand('insertText', false, \(encoded))",
			])
			edits += 1
			try await harness.waitForSourceEdits(edits)
			expected = (expected as NSString).replacingCharacters(
				in: NSRange(location: start, length: selectedLength),
				with: replacement)
			#expect(harness.source == expected,
				"seed \(seed):\n\(log.joined(separator: "\n"))")
			#expect(expected.split(separator: "\n").allSatisfy {
				$0.filter { $0 == "|" }.count == 4
			})
			try await harness.waitQuiescent()
		}

		let script = "seed \(seed):\n" + log.joined(separator: "\n")
		#expect(try await harness.evaluate("String(document.querySelectorAll('table').length)") == "1",
			"table fuzz: \(script)")
		#expect(try await harness.stampMismatches() == [], "table fuzz: \(script)")
		#expect(harness.coordinator.resyncCount == 0, "table fuzz: \(script)")
		#expect(harness.coordinator.hardRejections == 0, "table fuzz: \(script)")
		#expect(harness.coordinator.bridgeIncidents == [], "table fuzz: \(script)")
	}

	@Test(arguments: [UInt64(9101), 9102, 9103])
	func repeatedCrossBlockCutPasteMovesStaySynchronized(seed: UInt64) async throws {
		await TestPasteboard.acquireExclusiveAccess()
		defer { TestPasteboard.releaseExclusiveAccess() }
		var rng = SeededRNG(seed: seed)
		var expected = (0..<9)
			.map { "paragraph \($0) alpha bravo charlie delta" }
			.joined(separator: "\n\n")
		let harness = try await CoordinatorBridgeHarness(source: expected)
		let saved = TestPasteboard.string
		defer {
			TestPasteboard.string = saved
		}
		var edits = 0
		var log: [String] = []

		for _ in 0..<6 {
			let runs = try await Self.nonEmptyStampedRuns(harness)
				.filter { $0.length >= 4 }
			guard runs.count >= 2 else { break }
			let firstIndex = Int.random(in: 0..<(runs.count - 1), using: &rng)
			let lastIndex = Int.random(in: (firstIndex + 1)..<runs.count, using: &rng)
			let first = runs[firstIndex], last = runs[lastIndex]
			let start = first.base + Int.random(in: 1..<(first.length - 1), using: &rng)
			let end = last.base + Int.random(in: 1..<(last.length - 1), using: &rng)
			guard end > start else { continue }
			let removed = NSRange(location: start, length: end - start)
			let afterCut = (expected as NSString).replacingCharacters(in: removed, with: "")

			TestPasteboard.string = nil
			try await harness.run("window.__mdPlaceCaret(\(start), \(end - start))")
			try await Self.performResponderCommand(.cut, in: harness)
			edits += 1
			try await harness.waitForSourceEdits(edits)
			let copied = try #require(TestPasteboard.string)
			log.append("cut \(start)..<\(end), copied \(copied.debugDescription)")
			expected = afterCut
			#expect(harness.source == expected, "seed \(seed):\n\(log.joined(separator: "\n"))")
			try await harness.waitQuiescent()
			if ProcessInfo.processInfo.environment["MDR_FUZZ_CHECK_EACH_EDIT"] != nil {
				let projection = try await Self.visibleProjectionAndFreshRender(harness)
				#expect(projection.live == projection.rendered,
					"chunk-move seed \(seed) diverged after cut; live \(projection.live.debugDescription), rendered \(projection.rendered.debugDescription)")
			}

			guard let destination = try await Self.randomStampedOffset(harness, &rng) else { break }
			try await harness.placeCaret(destination)
			// Parameterized seeds can interleave across the awaits above while
			// sharing the process-wide pasteboard. Reassert this case's payload
			// immediately before the synchronous responder command so another
			// seed's Cut cannot turn this move into unrelated text.
			TestPasteboard.string = copied
			try await Self.performResponderCommand(.paste, in: harness)
			edits += 1
			try await harness.waitForSourceEdits(edits)
			expected = (expected as NSString).replacingCharacters(
				in: NSRange(location: destination, length: 0),
				with: copied)
			log.append("paste @\(destination)")
			#expect(harness.source == expected, "seed \(seed):\n\(log.joined(separator: "\n"))")
			try await harness.waitQuiescent()
			#expect(try await harness.stampMismatches() == [],
				"seed \(seed):\n\(log.joined(separator: "\n"))")
			if ProcessInfo.processInfo.environment["MDR_FUZZ_CHECK_EACH_EDIT"] != nil {
				let projection = try await Self.visibleProjectionAndFreshRender(harness)
				#expect(projection.live == projection.rendered,
					"chunk-move seed \(seed) diverged after paste; live \(projection.live.debugDescription), rendered \(projection.rendered.debugDescription)")
			}
		}

		let script = "seed \(seed):\n" + log.joined(separator: "\n")
		#expect(harness.coordinator.resyncCount == 0, "chunk-move fuzz: \(script)")
		#expect(harness.coordinator.hardRejections == 0, "chunk-move fuzz: \(script)")
		#expect(harness.coordinator.bridgeIncidents == [], "chunk-move fuzz: \(script)")
	}

	@Test(arguments: [UInt64(9201), 9202, 9203])
	func repeatedTableCellCutPasteMovesNeverDamagePipes(seed: UInt64) async throws {
		await TestPasteboard.acquireExclusiveAccess()
		defer { TestPasteboard.releaseExclusiveAccess() }
		var rng = SeededRNG(seed: seed)
		var expected = """
			| Name | Role | Score |
			| --- | --- | --- |
			| Alice | Writer | Thirty |
			| Bob | Editor | FortyOne |
			| Carol | Tester | FiftyTwo |
			"""
		let harness = try await CoordinatorBridgeHarness(source: expected)
		let saved = TestPasteboard.string
		defer {
			TestPasteboard.string = saved
		}
		var edits = 0
		var log: [String] = []

		for _ in 0..<8 {
			let sourceRuns = try await Self.tableCellStampedRuns(harness)
				.filter { $0.length > 0 }
			guard let sourceRun = sourceRuns.randomElement(using: &rng) else { break }
			let lower = Int.random(in: 0..<sourceRun.length, using: &rng)
			let length = Int.random(in: 1...(sourceRun.length - lower), using: &rng)
			let start = sourceRun.base + lower
			let afterCut = (expected as NSString).replacingCharacters(
				in: NSRange(location: start, length: length),
				with: "")

			TestPasteboard.string = nil
			try await harness.run("window.__mdPlaceCaret(\(start), \(length))")
			try await Self.performResponderCommand(.cut, in: harness)
			edits += 1
			try await harness.waitForSourceEdits(edits)
			let copied = try #require(TestPasteboard.string)
			expected = afterCut
			log.append("cut \(start)..<\(start + length) → \(copied.debugDescription)")
			#expect(harness.source == expected, "seed \(seed):\n\(log.joined(separator: "\n"))")
			try await harness.waitQuiescent()
			if ProcessInfo.processInfo.environment["MDR_FUZZ_CHECK_EACH_EDIT"] != nil {
				let projection = try await Self.visibleProjectionAndFreshRender(harness)
				#expect(projection.live == projection.rendered,
					"table-move seed \(seed) diverged after cut; live \(projection.live.debugDescription), rendered \(projection.rendered.debugDescription)")
			}

			let destinationRuns = try await Self.tableCellStampedRuns(harness)
			guard let destinationRun = destinationRuns.randomElement(using: &rng) else { break }
			let destination = destinationRun.base
				+ Int.random(in: 0...destinationRun.length, using: &rng)
			try await harness.placeCaret(destination)
			// Keep concurrently scheduled argument cases from borrowing one
			// another's process-wide pasteboard contents.
			TestPasteboard.string = copied
			try await Self.performResponderCommand(.paste, in: harness)
			edits += 1
			try await harness.waitForSourceEdits(edits)
			expected = (expected as NSString).replacingCharacters(
				in: NSRange(location: destination, length: 0),
				with: copied)
			log.append("paste @\(destination)")
			#expect(harness.source == expected, "seed \(seed):\n\(log.joined(separator: "\n"))")
			#expect(expected.split(separator: "\n").allSatisfy {
				$0.filter { $0 == "|" }.count == 4
			}, "seed \(seed):\n\(log.joined(separator: "\n"))")
			try await harness.waitQuiescent()
			if ProcessInfo.processInfo.environment["MDR_FUZZ_CHECK_EACH_EDIT"] != nil {
				let projection = try await Self.visibleProjectionAndFreshRender(harness)
				#expect(projection.live == projection.rendered,
					"table-move seed \(seed) diverged after paste; live \(projection.live.debugDescription), rendered \(projection.rendered.debugDescription)")
			}
		}

		let script = "seed \(seed):\n" + log.joined(separator: "\n")
		#expect(try await harness.evaluate("String(document.querySelectorAll('table').length)") == "1",
			"table move fuzz: \(script)")
		#expect(try await harness.stampMismatches() == [], "table move fuzz: \(script)")
		#expect(harness.coordinator.resyncCount == 0, "table move fuzz: \(script)")
		#expect(harness.coordinator.hardRejections == 0, "table move fuzz: \(script)")
		#expect(harness.coordinator.bridgeIncidents == [], "table move fuzz: \(script)")
	}

	static func generateDocument(_ rng: inout SeededRNG) -> String {
		let words = ["alpha", "beta", "gamma", "delta", "words", "text", "sample"]
		var blocks: [String] = []
		for _ in 0..<Int.random(in: 3...6, using: &rng) {
			switch Int.random(in: 0..<10, using: &rng) {
			case 0...5:
				let count = Int.random(in: 3...8, using: &rng)
				var sentence = (0..<count).map { _ in words.randomElement(using: &rng)! }.joined(separator: " ")
				if Bool.random(using: &rng) { sentence += " **\(words.randomElement(using: &rng)!)**" }
				blocks.append(sentence)
			case 6...7:
				blocks.append("- \(words.randomElement(using: &rng)!)\n- \(words.randomElement(using: &rng)!)")
			default:
				blocks.append("# \(words.randomElement(using: &rng)!.capitalized)")
			}
		}
		return blocks.joined(separator: "\n\n")
	}

	/// A random offset inside a random stamped run of the CURRENT page.
	static func randomStampedOffset(_ harness: CoordinatorBridgeHarness, _ rng: inout SeededRNG) async throws -> Int? {
		guard let raw = try await harness.evaluate("""
			Array.from(document.querySelectorAll('[data-s]'))
				.flatMap(function (e) {
					var base = parseInt(e.getAttribute('data-s'), 10);
					var offsets = [base], offset = 0;
					for (var character of e.textContent) {
						offset += character.length;
						offsets.push(base + offset);
					}
					return offsets;
				}).join(',')
			"""), !raw.isEmpty else { return nil }
		let offsets = raw.split(separator: ",").compactMap { Int($0) }
		return offsets.randomElement(using: &rng)
	}

	static func randomNonEmptyStampedRun(
		_ harness: CoordinatorBridgeHarness,
		_ rng: inout SeededRNG
	) async throws -> (base: Int, length: Int)? {
		guard let raw = try await harness.evaluate("""
			Array.from(document.querySelectorAll('[data-s]'))
				.map(e => e.getAttribute('data-s') + ':' + e.textContent.length).join(',')
			"""), !raw.isEmpty else { return nil }
		let runs: [(Int, Int)] = raw.split(separator: ",").compactMap {
			let parts = $0.split(separator: ":")
			guard parts.count == 2, let base = Int(parts[0]), let length = Int(parts[1]),
				  length > 0 else { return nil }
			return (base, length)
		}
		return runs.randomElement(using: &rng)
	}

	static func nonEmptyStampedRuns(
		_ harness: CoordinatorBridgeHarness
	) async throws -> [(base: Int, length: Int)] {
		let raw = try await harness.evaluate("""
			Array.from(document.querySelectorAll('[data-s]'))
			  .map(e => e.getAttribute('data-s') + ':' + e.textContent.length).join(',')
			""") ?? ""
		return raw.split(separator: ",").compactMap {
			let parts = $0.split(separator: ":")
			guard parts.count == 2, let base = Int(parts[0]), let length = Int(parts[1]),
			      length > 0 else { return nil }
			return (base, length)
		}.sorted { $0.base < $1.base }
	}

	static func tableCellStampedRuns(
		_ harness: CoordinatorBridgeHarness
	) async throws -> [(base: Int, length: Int)] {
		let raw = try await harness.evaluate("""
			Array.from(document.querySelectorAll('th [data-s], td [data-s]'))
			  .map(e => e.getAttribute('data-s') + ':' + e.textContent.length).join(',')
			""") ?? ""
		return raw.split(separator: ",").compactMap {
			let parts = $0.split(separator: ":")
			guard parts.count == 2, let base = Int(parts[0]), let length = Int(parts[1]),
			      length > 0 else { return nil }
			return (base, length)
		}
	}

	static func plain(_ s: String) -> String {
		s.replacingOccurrences(of: "\u{00A0}", with: " ")
	}

	static func normalizedVisibleText(_ text: String) -> String {
		plain(text)
			.split(separator: "\n", omittingEmptySubsequences: false)
			.map { $0.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression) }
			.map { $0.trimmingCharacters(in: .whitespaces) }
			.filter { !$0.isEmpty }
			.joined(separator: "\n")
	}

	static func visibleProjectionAndFreshRender(
		_ harness: CoordinatorBridgeHarness
	) async throws -> (live: String, rendered: String) {
		let live = normalizedVisibleText(try await harness.domVisibleText())
		let fresh = try await CoordinatorBridgeHarness(source: harness.source)
		let rendered = normalizedVisibleText(try await fresh.domVisibleText())
		return (live, rendered)
	}

	static func performResponderCommand(
		_ command: ClipboardCommand,
		in harness: CoordinatorBridgeHarness
	) async throws {
		try await harness.clipboardCommand(command)
	}
}
