//
//  RenderBenchmarkSupport.swift
//  MarkDownRangeTests
//
//  Fixtures and timing helpers for the render-pipeline benchmarks. These
//  deliberately exercise the *render* path (preprocess → parse → build the
//  NSAttributedString, including attachment sizing), which is where the styled
//  view spends its time — not just parsing. macOS-only because the builder and
//  its SwiftUI-hosted attachments are AppKit-bound.
//

import Foundation
import Testing
@testable import MarkDownRange

extension Tag {
	/// Marks the heavy performance benchmarks. They're gated off by default so
	/// they don't slow ordinary `swift test` runs.
	@Tag static var benchmark: Tag
}

/// Benchmarks are opt-in to keep the default test run fast. Enable with:
///   RUN_BENCHMARKS=1 swift test --filter RenderPipelineBenchmarks
enum BenchmarkGate {
	static var enabled: Bool { ProcessInfo.processInfo.environment["RUN_BENCHMARKS"] != nil }
}

// MARK: - Deterministic content fixtures

/// Builds Markdown documents that stress one content shape at a time, so a
/// benchmark can attribute cost to code blocks vs tables vs callouts vs images
/// etc. Everything is deterministic (index-driven, no randomness) so runs are
/// comparable over time.
enum RenderFixtures {
	/// Mostly-native text: headings, paragraphs, inline emphasis, links. The
	/// baseline — almost no attachments, so it isolates text-run cost.
	static func prose(paragraphs: Int) -> String {
		var out: [String] = []
		for i in 0..<paragraphs {
			out.append("## Section \(i): The quick brown fox")
			out.append("")
			out.append("Paragraph \(i) with **bold**, *italic*, `inline code`, ~~strike~~ and a [link](https://example.com/\(i)). Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam quis nostrud exercitation.")
			out.append("")
		}
		return out.joined(separator: "\n")
	}

	/// N fenced code blocks. `identical: true` makes every block structurally
	/// the same (so the attachment size cache hits after the first); `false`
	/// varies line count per block so every one misses the cache — the
	/// realistic cold cost.
	static func codeBlocks(_ count: Int, identical: Bool = false) -> String {
		let langs = ["swift", "python", "javascript", "json"]
		var out: [String] = []
		for i in 0..<count {
			let lines = identical ? 20 : 5 + (i % 50)
			out.append("```\(langs[i % langs.count])")
			out.append(contentsOf: codeBody(lines: lines, salt: i))
			out.append("```")
			out.append("")
		}
		return out.joined(separator: "\n")
	}

	/// N tables. `identical` controls cache-hit behavior as in `codeBlocks`.
	static func tables(_ count: Int, identical: Bool = false) -> String {
		var out: [String] = []
		for i in 0..<count {
			let cols = identical ? 4 : 2 + (i % 5)
			let rows = identical ? 8 : 3 + (i % 25)
			let header = (0..<cols).map { "Col \($0)" }.joined(separator: " | ")
			let sep = (0..<cols).map { _ in "---" }.joined(separator: " | ")
			out.append("| \(header) |")
			out.append("| \(sep) |")
			for r in 0..<rows {
				let cells = (0..<cols).map { "r\(r)c\($0)" }.joined(separator: " | ")
				out.append("| \(cells) |")
			}
			out.append("")
		}
		return out.joined(separator: "\n")
	}

	/// N callouts (GitHub alerts) and collapsible `<details>` blocks — none of
	/// which the size cache covers, so every one is measured.
	static func callouts(_ count: Int) -> String {
		let kinds = ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"]
		var out: [String] = []
		for i in 0..<count {
			if i.isMultiple(of: 2) {
				out.append("> [!\(kinds[i % kinds.count])]")
				out.append("> Callout \(i) body line one with some **emphasis**.")
				out.append("> And a second line for height.")
			} else {
				out.append("<details><summary>Details \(i)</summary>")
				out.append("")
				out.append("Hidden content for block \(i) with a `code` span.")
				out.append("")
				out.append("</details>")
			}
			out.append("")
		}
		return out.joined(separator: "\n")
	}

	/// Deeply nested ordered/unordered/task lists — heavy native text layout.
	static func lists(_ count: Int) -> String {
		var out: [String] = []
		for i in 0..<count {
			out.append("- Item \(i) with **bold** and a [link](https://example.com/\(i))")
			out.append("  - Nested \(i).1 with `code`")
			out.append("    1. Deep \(i).1.1")
			out.append("    2. Deep \(i).1.2")
			out.append("  - [ ] Task \(i) pending")
			out.append("  - [x] Task \(i) done")
		}
		out.append("")
		return out.joined(separator: "\n")
	}

	/// A realistic mixed document: each section has prose, a code block, a
	/// list, a callout, and a table. Mirrors the app's "real document" shape.
	static func mixed(sections: Int) -> String {
		var out: [String] = []
		out.append("---\ntitle: Benchmark\nauthor: Suite\n---\n")
		for i in 0..<sections {
			out.append("# Section \(i)")
			out.append("")
			out.append("Intro with **bold**, *italic*, `code`, and a [link](https://example.com/\(i)).")
			out.append("")
			out.append("```swift")
			out.append(contentsOf: codeBody(lines: 12, salt: i))
			out.append("```")
			out.append("")
			out.append("- Point one\n- Point two\n  - Nested\n- [x] Done")
			out.append("")
			out.append("> [!NOTE]\n> A note for section \(i).")
			out.append("")
			out.append("| A | B | C |\n| --- | --- | --- |\n| \(i).1 | \(i).2 | \(i).3 |\n| \(i).4 | \(i).5 | \(i).6 |")
			out.append("")
		}
		return out.joined(separator: "\n")
	}

	private static func codeBody(lines: Int, salt: Int) -> [String] {
		var body: [String] = []
		for i in 0..<lines {
			switch i % 6 {
			case 0: body.append("let value\(salt)_\(i) = \"literal \\(interpolated)\"")
			case 1: body.append("// comment on line \(i) of block \(salt)")
			case 2: body.append("func process\(i)(_ input: String) async throws -> Int {")
			case 3: body.append("    return input.count * \(i) + 0xFF")
			case 4: body.append("}")
			default: body.append("")
			}
		}
		return body
	}
}

#if os(macOS)
import AppKit

extension RenderFixtures {
	/// Writes `count` distinct tiny PNGs into `directory` and returns Markdown
	/// referencing them relatively (resolve with `directory` as the base URL).
	/// Distinct dimensions so image-dimension reads aren't trivially cached.
	static func images(_ count: Int, into directory: URL) -> String {
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		var out: [String] = []
		for i in 0..<count {
			let name = "img\(i).png"
			writePNG(width: 80 + (i % 40), height: 60 + (i % 30), to: directory.appendingPathComponent(name))
			out.append("![image \(i)](\(name))")
			out.append("")
		}
		return out.joined(separator: "\n")
	}

	private static func writePNG(width: Int, height: Int, to url: URL) {
		let image = NSImage(size: NSSize(width: width, height: height))
		image.lockFocus()
		NSColor.systemGray.setFill()
		NSRect(x: 0, y: 0, width: width, height: height).fill()
		image.unlockFocus()
		guard let tiff = image.tiffRepresentation,
			  let rep = NSBitmapImageRep(data: tiff),
			  let png = rep.representation(using: .png, properties: [:]) else { return }
		try? png.write(to: url)
	}
}

// MARK: - Timing

/// One render measured across its three phases plus the attachment/text split
/// the builder reports. Times are milliseconds.
@MainActor
struct RenderTiming {
	let label: String
	let chars: Int
	let lines: Int
	let blocks: Int
	let preprocessMs: Double
	let parseMs: Double
	/// Build wall-clock with an empty attachment size cache (fresh document).
	let buildMs: Double
	/// Build wall-clock with the size cache already populated (steady state).
	let warmBuildMs: Double
	let attachMs: Double
	let attachCount: Int
	let textMs: Double
	let textCount: Int

	/// Cold total — what the user waits for when opening a document fresh.
	var totalMs: Double { preprocessMs + parseMs + buildMs }

	func report() {
		func f(_ v: Double) -> String { String(format: "%7.1f", v) }
		let head = label.padding(toLength: 26, withPad: " ", startingAt: 0)
		print("\(head) | blk \(String(format: "%4d", blocks)) att \(String(format: "%4d", attachCount)) | "
			+ "pre \(f(preprocessMs)) parse \(f(parseMs)) build \(f(buildMs)) "
			+ "(att \(f(attachMs)) txt \(f(textMs))) warm-build \(f(warmBuildMs)) | total \(f(totalMs)) ms  [\(chars) chars, \(lines) lines]")
	}
}

@MainActor
enum RenderBench {
	/// Median elapsed milliseconds over `iterations` synchronous runs.
	static func measure(_ iterations: Int = 3, _ work: () -> Void) -> Double {
		median((0..<iterations).map { _ in
			let t0 = CFAbsoluteTimeGetCurrent()
			work()
			return (CFAbsoluteTimeGetCurrent() - t0) * 1000
		})
	}

	/// Median elapsed milliseconds over `iterations` async runs.
	static func measureAsync(_ iterations: Int = 3, _ work: () async -> Void) async -> Double {
		var times: [Double] = []
		for _ in 0..<iterations {
			let t0 = CFAbsoluteTimeGetCurrent()
			await work()
			times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
		}
		return median(times)
	}

	/// Times the full render pipeline for `markdown`, returning a `RenderTiming`.
	/// Local images are dimension-prefetched first (as the live renderer does)
	/// so their decode cost doesn't masquerade as build time on the first run.
	static func render(_ label: String, _ markdown: String, baseURL: URL? = nil, width: CGFloat = 700, iterations: Int = 3) async -> RenderTiming {
		let processed = MarkdownPreprocessor.process(markdown)
		let preprocessMs = measure(iterations) { _ = MarkdownPreprocessor.process(markdown) }
		let parseMs = measure(iterations) { _ = MarkdownBlockParser.parse(processed, preprocessed: true) }
		let blocks = MarkdownBlockParser.parse(markdown)
		if baseURL != nil { prefetchLocalImages(in: blocks, baseURL: baseURL) }

		// Cold: clear the size cache so every attachment is measured, and read
		// the build's own per-block metrics from this same (cold) run.
		MarkdownAttachmentSizeCache.shared.removeAll()
		let buildMs = await measureAsync(1) {
			_ = await MarkdownAttributedStringBuilder.build(blocks: blocks, theme: .default, fontSize: 16, baseURL: baseURL, availableWidth: width)
		}
		let metrics = MarkdownAttributedStringBuilder.lastBuildMetrics
		// Warm: the size cache is now populated; this is steady-state cost.
		let warmBuildMs = await measureAsync(max(1, iterations - 1)) {
			_ = await MarkdownAttributedStringBuilder.build(blocks: blocks, theme: .default, fontSize: 16, baseURL: baseURL, availableWidth: width)
		}
		return RenderTiming(
			label: label,
			chars: markdown.count,
			lines: markdown.components(separatedBy: "\n").count,
			blocks: blocks.count,
			preprocessMs: preprocessMs,
			parseMs: parseMs,
			buildMs: buildMs,
			warmBuildMs: warmBuildMs,
			attachMs: metrics?.attachMs ?? 0,
			attachCount: metrics?.attachCount ?? 0,
			textMs: metrics?.textMs ?? 0,
			textCount: metrics?.textCount ?? 0
		)
	}

	private static func median(_ values: [Double]) -> Double {
		guard !values.isEmpty else { return 0 }
		let sorted = values.sorted()
		return sorted[sorted.count / 2]
	}

	private static func prefetchLocalImages(in blocks: [MarkdownBlock], baseURL: URL?) {
		for block in blocks {
			switch block {
			case .image(let source, _, _, _, _): prefetch(source, baseURL)
			case .imageRow(let images, _): images.forEach { prefetch($0.source, baseURL) }
			case .figure(let item, _, _): prefetch(item.source, baseURL)
			default: break
			}
		}
	}

	private static func prefetch(_ source: String, _ baseURL: URL?) {
		let url: URL?
		if let direct = URL(string: source), direct.scheme != nil { url = direct }
		else if let base = baseURL { url = URL(string: source, relativeTo: base) }
		else { url = nil }
		if let url { ImageDimensionCache.shared.prefetchSyncIfLocal(url) }
	}
}
#endif
