//
//  PreprocessorParityTests.swift
//  FeltTip
//
//  Byte-for-byte parity of the preprocessor against a recorded fixture over
//  the 900-document sample corpus, in both display and editable modes. The
//  fixture pins the output of the implementation that preceded the UTF-8
//  rewrite of the per-line pass. Regenerate it only for an intentional
//  behavior change: FELTTIP_REGENERATE_FIXTURES=1. Opt in to run it:
//  FELTTIP_RUN_PARITY=1 (it preprocesses ~17 MB of Markdown).
//

import CryptoKit
import Foundation
import Testing
@testable import FeltTip

@Suite(.enabled(if: ProcessInfo.processInfo.environment["FELTTIP_RUN_PARITY"] == "1"))
struct PreprocessorParityTests {
	static let fixtureURL = URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent()
		.appendingPathComponent("Fixtures/preprocessor-parity.json")

	struct Digest: Codable, Equatable {
		let display: String
		let editable: String
		let editableMap: String
	}

	private static func sha(_ string: String) -> String {
		SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
	}

	private static func digest(_ markdown: String) -> Digest {
		let display = MarkdownPreprocessor.process(markdown)
		let tracked = MarkdownPreprocessor.processTrackingOptionalOffsets(markdown, options: .default)
		let map = tracked.map.map { $0.map(String.init).joined(separator: ",") } ?? "identity"
		return Digest(display: sha(display), editable: sha(tracked.processed), editableMap: sha(map))
	}

	@Test func preprocessorOutputMatchesRecordedFixture() throws {
		let files = try FileManager.default
			.contentsOfDirectory(at: PipelineBenchmarkTests.samplesDir, includingPropertiesForKeys: nil)
			.filter { $0.pathExtension.lowercased() == "md" }
			.sorted { $0.lastPathComponent < $1.lastPathComponent }
		#expect(files.count > 800)
		var digests: [String: Digest] = [:]
		for file in files {
			let text = try String(contentsOf: file, encoding: .utf8)
			digests[file.lastPathComponent] = Self.digest(text)
		}
		if ProcessInfo.processInfo.environment["FELTTIP_REGENERATE_FIXTURES"] == "1" {
			let encoder = JSONEncoder()
			encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
			try encoder.encode(digests).write(to: Self.fixtureURL)
			print("[Parity] wrote \(digests.count) digests to \(Self.fixtureURL.path)")
			return
		}
		let recorded = try JSONDecoder().decode(
			[String: Digest].self, from: Data(contentsOf: Self.fixtureURL))
		var mismatches: [String] = []
		for (name, digest) in digests where recorded[name] != digest {
			mismatches.append(name)
		}
		#expect(mismatches.isEmpty, "preprocessor output changed for: \(mismatches.sorted().prefix(20))")
	}
}

/// The byte-level fast paths must agree with the grapheme-based processors
/// they shadow on every ASCII line. Random lines drawn from the characters
/// those processors care about exercise the segment-boundary and
/// word-boundary rules far more densely than real prose does.
@Suite struct ASCIIFastPathDifferentialTests {
	static let alphabet: [Character] = Array("ab Zx\"'`<>()[]{}-+.=:;8!?,|_*\t#^~/\\")

	private func randomLine(_ rng: inout SplitMix64) -> String {
		let length = Int(rng.next() % 40)
		var line = ""
		for _ in 0..<length {
			line.append(Self.alphabet[Int(rng.next() % UInt64(Self.alphabet.count))])
		}
		return line
	}

	private func resolve(_ result: ASCIILineResult, _ line: String) -> String {
		switch result {
		case .unchanged: return line
		case .changed(let s): return s
		case .notASCII: return "<<notASCII>>"
		}
	}

	@Test func smartQuotesMatchOnRandomASCIILines() {
		var rng = SplitMix64(seed: 1)
		for _ in 0..<40_000 {
			let line = randomLine(&rng)
			let expected = SmartQuotes.applyLine(line)
			let actual = resolve(SmartQuotes.applyASCIILine(line), line)
			#expect(actual == expected, "line: \(line.debugDescription)")
			if actual != expected { return }
		}
	}

	@Test func smartTypographyMatchesOnRandomASCIILines() {
		var rng = SplitMix64(seed: 2)
		for _ in 0..<40_000 {
			let line = randomLine(&rng)
			let expected = SmartTypography.applyLine(line)
			let actual = resolve(SmartTypography.applyASCIILine(line), line)
			#expect(actual == expected, "line: \(line.debugDescription)")
			if actual != expected { return }
		}
	}

	@Test func emoticonsMatchOnRandomASCIILines() {
		var rng = SplitMix64(seed: 3)
		for _ in 0..<40_000 {
			let line = randomLine(&rng)
			let expected = EmoticonShortcodes.applyLine(line)
			let actual = resolve(EmoticonShortcodes.applyASCIILine(line), line)
			#expect(actual == expected, "line: \(line.debugDescription)")
			if actual != expected { return }
		}
	}

	@Test func nonASCIILinesAreRefused() {
		#expect({ if case .notASCII = SmartQuotes.applyASCIILine("say \"héllo\"") { return true }; return false }())
		#expect({ if case .notASCII = SmartTypography.applyASCIILine("(c) café") { return true }; return false }())
		#expect({ if case .notASCII = EmoticonShortcodes.applyASCIILine(":) café") { return true }; return false }())
	}
}

struct SplitMix64 {
	var state: UInt64
	init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
	mutating func next() -> UInt64 {
		state &+= 0x9E37_79B9_7F4A_7C15
		var z = state
		z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
		z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
		return z ^ (z >> 31)
	}
}
