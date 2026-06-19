//
//  ScrollBenchmarks.swift
//  MarkDownRangeTests
//
//  Scroll-time benchmarks. Opt in with:
//      RUN_BENCHMARKS=1 swift test --filter ScrollBenchmarks
//

import Testing
import Foundation
@testable import MarkDownRange

#if os(macOS)

@Suite(.tags(.benchmark), .enabled(if: BenchmarkGate.enabled), .serialized)
struct ScrollBenchmarks {
	@Test @MainActor func byContentType() async {
		print("\n— per-frame scroll cost by content type (60-frame top-to-bottom sweep) —")
		print("  (incremental = good path; full-relayout = jank path; excludes attachment view mounting — see AttachmentSizingBenchmarks)")
		(await ScrollBench.sweep("prose/300", RenderFixtures.prose(paragraphs: 300))).report()
		(await ScrollBench.sweep("lists/300", RenderFixtures.lists(300))).report()
		(await ScrollBench.sweep("code/80", RenderFixtures.codeBlocks(80))).report()
		(await ScrollBench.sweep("tables/80", RenderFixtures.tables(80))).report()
		(await ScrollBench.sweep("callouts/80", RenderFixtures.callouts(80))).report()
		(await ScrollBench.sweep("mixed/80", RenderFixtures.mixed(sections: 80))).report()
	}

	@Test @MainActor func images() async {
		print("\n— per-frame scroll cost, image-heavy —")
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mdr-bench-images")
		let markdown = RenderFixtures.images(80, into: dir)
		(await ScrollBench.sweep("images/80", markdown, baseURL: dir)).report()
	}

	@Test @MainActor func scaleWithDocumentLength() async {
		print("\n— scroll cost vs document length (mixed content) —")
		for n in [40, 120, 300] {
			(await ScrollBench.sweep("mixed/\(n)", RenderFixtures.mixed(sections: n))).report()
		}
	}

	@Test @MainActor func realWorldSample() async {
		print("\n— scroll cost on a real document —")
		let samples = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent().deletingLastPathComponent()
			.deletingLastPathComponent().deletingLastPathComponent()
			.appendingPathComponent("Misc/sample_markdowns")
		let url = samples.appendingPathComponent("public-apis__public-apis__README.md")
		guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
		(await ScrollBench.sweep("public-apis", text)).report()
	}
}

#endif
