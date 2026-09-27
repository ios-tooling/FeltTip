//
//  PipelineBenchmarkTests.swift
//  FeltTip
//

import Testing
import Foundation
import Markdown
@testable import FeltTip

@Suite struct PipelineBenchmarkTests {
	static let samplesDir = URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent()
		.deletingLastPathComponent()
		.deletingLastPathComponent()
		.appendingPathComponent("Misc/sample_markdowns")

	static let largeFile = samplesDir.appendingPathComponent("vsouza__awesome-ios__README.md")
	static let mediumFile = samplesDir.appendingPathComponent("public-apis__public-apis__README.md")

	private func loadFile(_ url: URL) throws -> String {
		try String(contentsOf: url, encoding: .utf8)
	}

	@Test func baselineLargeFile() throws {
		let text = try loadFile(Self.largeFile)
		print("Large file: \(text.count) chars, \(text.components(separatedBy: "\n").count) lines")

		let start = CFAbsoluteTimeGetCurrent()
		let blocks = MarkdownBlockParser.parse(text)
		let elapsed = CFAbsoluteTimeGetCurrent() - start

		print("Full parse: \(String(format: "%.3f", elapsed))s → \(blocks.count) blocks")
		#expect(!blocks.isEmpty)
	}

	@Test func baselineMediumFile() throws {
		let text = try loadFile(Self.mediumFile)
		print("Medium file: \(text.count) chars, \(text.components(separatedBy: "\n").count) lines")

		let start = CFAbsoluteTimeGetCurrent()
		let blocks = MarkdownBlockParser.parse(text)
		let elapsed = CFAbsoluteTimeGetCurrent() - start

		print("Full parse: \(String(format: "%.3f", elapsed))s → \(blocks.count) blocks")
		#expect(!blocks.isEmpty)
	}

	@Test func parseWithoutLinkify() throws {
		let text = try loadFile(Self.largeFile)
		let doc = Document(parsing: text)

		let t0 = CFAbsoluteTimeGetCurrent()
		var builder = BlockBuilder(theme: .default, fontSize: 16, checkboxCounter: CheckboxCounter(0))
		let blocks = builder.build(from: doc, linkifyURLs: false)
		let t1 = CFAbsoluteTimeGetCurrent()

		print("BlockBuilder WITHOUT linkify: \(String(format: "%.3f", t1 - t0))s → \(blocks.count) blocks")
		#expect(!blocks.isEmpty)
	}

	@Test func pipelineBreakdownLargeFile() throws {
		let text = try loadFile(Self.largeFile)

		let t0 = CFAbsoluteTimeGetCurrent()
		let emoji = EmojiShortcodes.process(text)
		let t1 = CFAbsoluteTimeGetCurrent()

		let highlight = HighlightSyntax.process(emoji)
		let t2 = CFAbsoluteTimeGetCurrent()

		let doc = Document(parsing: highlight)
		let t3 = CFAbsoluteTimeGetCurrent()

		var builder = BlockBuilder(theme: .default, fontSize: 16, checkboxCounter: CheckboxCounter(0))
		let blocks = builder.build(from: doc)
		let t4 = CFAbsoluteTimeGetCurrent()

		print("Pipeline breakdown (large \(text.count) chars):")
		print("  EmojiShortcodes:   \(String(format: "%.3f", t1 - t0))s")
		print("  HighlightSyntax:   \(String(format: "%.3f", t2 - t1))s")
		print("  Document(parsing): \(String(format: "%.3f", t3 - t2))s")
		print("  BlockBuilder:      \(String(format: "%.3f", t4 - t3))s")
		print("  Total:             \(String(format: "%.3f", t4 - t0))s → \(blocks.count) blocks")
		#expect(!blocks.isEmpty)
	}

	@Test func plainDocumentsSkipCitationAndFootnoteLinePasses() {
		let text = (0..<50_000)
			.map { "Ordinary paragraph \($0) with no note syntax." }
			.joined(separator: "\n")

		let elapsed = ContinuousClock().measure {
			#expect(Citation.parse(from: text).isEmpty)
			#expect(MarkdownFootnote.parse(from: text).isEmpty)
		}

		#expect(elapsed < .milliseconds(100), "absent note parsing took \(elapsed)")
	}

	@Test func plainDocumentPreprocessingAvoidsSlowFeatureSearches() {
		let text = (0..<50_000)
			.map { "Ordinary paragraph \($0) with no extension syntax." }
			.joined(separator: "\n")
		var processed = ""

		let elapsed = ContinuousClock().measure {
			processed = MarkdownPreprocessor.process(text)
		}

		#expect(processed == text)
		#expect(elapsed < .milliseconds(300), "plain preprocessing took \(elapsed)")
	}
}
