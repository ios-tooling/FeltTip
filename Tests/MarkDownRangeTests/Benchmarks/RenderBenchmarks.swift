//
//  RenderBenchmarks.swift
//  MarkDownRangeTests
//
//  Measures the styled-view render pipeline (preprocess → parse → build the
//  NSAttributedString, including SwiftUI-hosted attachment sizing). Run with:
//      swift test --filter RenderPipelineBenchmarks
//      swift test --filter AttachmentSizingBenchmarks
//  These print timings; they assert only sanity, not thresholds, so they don't
//  flake on slower machines — read the console output.
//

import Testing
import Foundation
@testable import MarkDownRange

#if os(macOS)

@Suite(.tags(.benchmark), .enabled(if: BenchmarkGate.enabled), .serialized)
struct RenderPipelineBenchmarks {
	@Test @MainActor func prose() async {
		print("\n— prose (heading/paragraph/inline, ~no attachments) —")
		for n in [50, 200, 800] {
			(await RenderBench.render("prose/\(n)", RenderFixtures.prose(paragraphs: n))).report()
		}
	}

	@Test @MainActor func codeBlocks() async {
		print("\n— code blocks (attachment, tokenized) —")
		for n in [20, 80, 200] {
			(await RenderBench.render("code/\(n)", RenderFixtures.codeBlocks(n))).report()
		}
	}

	@Test @MainActor func tables() async {
		print("\n— tables (attachment, grid layout) —")
		for n in [20, 80, 200] {
			(await RenderBench.render("table/\(n)", RenderFixtures.tables(n))).report()
		}
	}

	@Test @MainActor func callouts() async {
		print("\n— callouts + details (attachment, not size-cached) —")
		for n in [20, 80, 200] {
			(await RenderBench.render("callout/\(n)", RenderFixtures.callouts(n))).report()
		}
	}

	@Test @MainActor func lists() async {
		print("\n— nested lists (native text) —")
		for n in [50, 200, 600] {
			(await RenderBench.render("list/\(n)", RenderFixtures.lists(n))).report()
		}
	}

	@Test @MainActor func mixed() async {
		print("\n— mixed realistic document —")
		for n in [10, 50, 150] {
			(await RenderBench.render("mixed/\(n)", RenderFixtures.mixed(sections: n))).report()
		}
	}

	@Test @MainActor func images() async {
		print("\n— images (attachment, dimension decode) —")
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mdr-bench-images")
		for n in [20, 60] {
			let md = RenderFixtures.images(n, into: dir)
			(await RenderBench.render("image/\(n)", md, baseURL: dir)).report()
		}
	}

	@Test @MainActor func realWorldSamples() async throws {
		print("\n— real-world sample documents —")
		let samples = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent().deletingLastPathComponent()
			.deletingLastPathComponent().deletingLastPathComponent()
			.appendingPathComponent("Misc/sample_markdowns")
		for name in ["public-apis__public-apis__README.md", "vsouza__awesome-ios__README.md"] {
			let url = samples.appendingPathComponent(name)
			guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
			(await RenderBench.render(String(name.prefix(22)), text)).report()
		}
	}
}

/// Isolates the per-attachment sizing cost (the `NSHostingController.sizeThatFits`
/// hypothesis) and the size-cache effect.
@Suite(.tags(.benchmark), .enabled(if: BenchmarkGate.enabled), .serialized)
struct AttachmentSizingBenchmarks {
	@Test @MainActor func codeBlockCacheEffect() async {
		print("\n— code block: cache miss (distinct) vs hit (identical), 120 blocks —")
		let distinct = await RenderBench.render("code-distinct/120", RenderFixtures.codeBlocks(120, identical: false))
		let identical = await RenderBench.render("code-identical/120", RenderFixtures.codeBlocks(120, identical: true))
		distinct.report()
		identical.report()
		printPerAttachment("code block", distinct)
		print("  cache saving: \(String(format: "%.1f", distinct.attachMs - identical.attachMs)) ms over 120 blocks")
		#expect(distinct.attachCount > 0)
	}

	@Test @MainActor func tableCacheEffect() async {
		print("\n— table: cache miss (distinct) vs hit (identical), 120 tables —")
		let distinct = await RenderBench.render("table-distinct/120", RenderFixtures.tables(120, identical: false))
		let identical = await RenderBench.render("table-identical/120", RenderFixtures.tables(120, identical: true))
		distinct.report()
		identical.report()
		printPerAttachment("table", distinct)
		print("  cache saving: \(String(format: "%.1f", distinct.attachMs - identical.attachMs)) ms over 120 tables")
		#expect(distinct.attachCount > 0)
	}

	@Test @MainActor func perAttachmentTypeCost() async {
		print("\n— average sizing cost per attachment, by type (100 distinct each) —")
		printPerAttachment("code block", await RenderBench.render("code/100", RenderFixtures.codeBlocks(100)))
		printPerAttachment("table", await RenderBench.render("table/100", RenderFixtures.tables(100)))
		printPerAttachment("callout/details", await RenderBench.render("callout/100", RenderFixtures.callouts(100)))
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mdr-bench-images")
		let img = await RenderBench.render("image/100", RenderFixtures.images(100, into: dir), baseURL: dir)
		printPerAttachment("image", img)
	}

	@Test @MainActor func attachmentShareOfMixedDoc() async {
		print("\n— what share of a mixed render is attachment sizing? —")
		let timing = await RenderBench.render("mixed/100", RenderFixtures.mixed(sections: 100))
		timing.report()
		let share = timing.totalMs > 0 ? timing.attachMs / timing.totalMs * 100 : 0
		print("  attachment sizing = \(String(format: "%.1f", share))% of total render time")
		#expect(timing.blocks > 0)
	}

	@MainActor private func printPerAttachment(_ kind: String, _ t: RenderTiming) {
		let per = t.attachCount > 0 ? t.attachMs / Double(t.attachCount) : 0
		print("  \(kind.padding(toLength: 16, withPad: " ", startingAt: 0)) \(String(format: "%.2f", per)) ms/attachment  (\(t.attachCount) attachments, \(String(format: "%.1f", t.attachMs)) ms total)")
	}
}

#endif
