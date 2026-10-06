//
//  RenderLatencyBenchmarkTests.swift
//  FeltTip
//
//  End-to-end timings for the two paths the editors pay for most: a full
//  parse of a large document in display and editable (source-offset) modes,
//  and the re-render that follows a one-character structural edit. The block
//  diff itself is covered by BlockPatchBenchmarkTests; these cover everything
//  that runs before it. Timings always print; the bounds are deliberately
//  loose so only a pathological regression fails CI.
//

import Foundation
import Testing
@testable import FeltTip

@Suite(.serialized) struct RenderLatencyBenchmarkTests {
	static let largeFile = PipelineBenchmarkTests.samplesDir
		.appendingPathComponent("vsouza__awesome-ios__README.md")

	private func load() throws -> String {
		try String(contentsOf: Self.largeFile, encoding: .utf8)
	}

	private func report(_ label: String, _ seconds: Double, extra: String = "") {
		print(String(format: "[Bench] %@: %.0f ms %@", label, seconds * 1000, extra))
	}

	@Test func displayParseOfALargeDocument() throws {
		let text = try load()
		_ = MarkdownBlockParser.parse(text)
		MarkdownPreprocessor.recordsPerformanceMetrics = true
		defer { MarkdownPreprocessor.recordsPerformanceMetrics = false }
		let start = CFAbsoluteTimeGetCurrent()
		let blocks = MarkdownBlockParser.parse(text)
		let elapsed = CFAbsoluteTimeGetCurrent() - start
		// The stage timings are a process-wide record; a parallel suite's parse
		// can reset them, so only report them when they survived intact.
		let timings = MarkdownPreprocessor.recordedTimings
		let stages = timings.values.reduce(0, +) > 0
			? timings.sorted { $0.value > $1.value }
				.map { String(format: "%@=%.0f", $0.key, $0.value) }
				.joined(separator: " ")
			: "stage timings unavailable under parallel load"
		report("display parse", elapsed, extra: "(\(blocks.count) blocks; \(stages))")
		#expect(!blocks.isEmpty)
		#expect(elapsed < 2.0)
	}

	@Test func editableParseOfALargeDocument() throws {
		let text = try load()
		_ = MarkdownBlockParser.parse(text, trackSourceOffsets: true)
		MarkdownPreprocessor.recordsPerformanceMetrics = true
		defer { MarkdownPreprocessor.recordsPerformanceMetrics = false }
		let start = CFAbsoluteTimeGetCurrent()
		let blocks = MarkdownBlockParser.parse(text, trackSourceOffsets: true)
		let elapsed = CFAbsoluteTimeGetCurrent() - start
		let phases = MarkdownBlockParser.lastParseMetrics.map {
			String(format: "pre=%.0f doc=%.0f build=%.0f post=%.0f", $0.preprocessMs, $0.docInitMs, $0.blockBuildMs, $0.postProcessMs)
		} ?? ""
		report("editable parse", elapsed, extra: "(\(blocks.count) blocks; \(phases))")
		#expect(!blocks.isEmpty)
		#expect(elapsed < 2.0)
	}

	@Test(arguments: [false, true])
	func oneCharacterStructuralEditRerender(includeSourceOffsets: Bool) async throws {
		let text = try load()
		let service = MarkdownRenderService()
		let baseline = await service.blockResult(
			markdown: text, theme: .default, fontSize: 14,
			includeSourceOffsets: includeSourceOffsets, interactiveCheckboxes: true)
		var edited = text
		edited.insert("X", at: edited.index(edited.startIndex, offsetBy: edited.count / 2))
		let start = CFAbsoluteTimeGetCurrent()
		let result = await service.blockResult(
			markdown: edited, theme: .default, fontSize: 14,
			includeSourceOffsets: includeSourceOffsets, interactiveCheckboxes: true,
			baseline: baseline.fragments)
		let elapsed = CFAbsoluteTimeGetCurrent() - start
		let patch = result.patch.map { "\($0.removeCount) removed, \($0.html.count) inserted" } ?? "full swap"
		report("one-char edit re-render (offsets=\(includeSourceOffsets))", elapsed, extra: "(\(patch))")
		#expect(result.patch != nil, "a one-character edit should patch, not swap")
		#expect(elapsed < 2.5)
	}
}
