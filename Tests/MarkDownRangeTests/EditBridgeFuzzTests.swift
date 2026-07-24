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
		#expect(harness.coordinator.resyncCount == 0, "resyncs during \(script)")

		// Convergence: a fresh render of the final source must project the
		// same text as the live DOM (modulo WebKit's NBSP churn).
		let live = Self.plain(try await harness.domProjectedText())
		let fresh = try await CoordinatorBridgeHarness(source: harness.source)
		let rendered = Self.plain(try await fresh.domProjectedText())
		#expect(live == rendered, "source and DOM diverged after \(script)\nlive:     \(live)\nrendered: \(rendered)")
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
				.map(e => e.getAttribute('data-s') + ':' + e.textContent.length).join(',')
			"""), !raw.isEmpty else { return nil }
		let runs: [(Int, Int)] = raw.split(separator: ",").compactMap {
			let parts = $0.split(separator: ":")
			guard parts.count == 2, let base = Int(parts[0]), let len = Int(parts[1]) else { return nil }
			return (base, len)
		}
		guard let run = runs.randomElement(using: &rng) else { return nil }
		return run.0 + Int.random(in: 0...run.1, using: &rng)
	}

	static func plain(_ s: String) -> String {
		s.replacingOccurrences(of: "\u{00A0}", with: " ")
	}
}
#endif
