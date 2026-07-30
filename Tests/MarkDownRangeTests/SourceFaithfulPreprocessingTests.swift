import Testing
@testable import MarkDownRange

/// Editable rendering must show the file's own characters: cosmetic
/// substitutions would make rendered run text diverge from the source and
/// break the run-offset arithmetic the editors rely on.
@Suite struct SourceFaithfulPreprocessingTests {
	@Test func trackingPreservesSourceCharacters() {
		let source = "He said \"hi\" -- twice... :smile: and :-) done"
		let (processed, map) = MarkdownPreprocessor.processTrackingOffsets(source)
		#expect(processed == source)
		#expect(map == Array(0..<source.utf16.count))
	}

	@Test func nonTrackingStillAppliesCosmetics() {
		let processed = MarkdownPreprocessor.process("He said \"hi\" -- twice... :smile: done")
		#expect(!processed.contains("--"))
		#expect(!processed.contains("..."))
		#expect(!processed.contains("\"hi\""))
		#expect(!processed.contains(":smile:"))
	}

	@Test func trackingKeepsStructuralPasses() {
		// Highlight still rewrites (it becomes markup, not different run
		// text), and the diff map still covers whatever length change it makes.
		let source = "some ==marked== text"
		let (processed, map) = MarkdownPreprocessor.processTrackingOffsets(source)
		#expect(!processed.contains("=="))
		#expect(map.count == (processed as NSString).length)
	}

	@Test func parserTrackingKeepsIdentityMapsImplicitForLargePlainSource() {
		let source = (0..<10_000)
			.map { "Plain paragraph \($0) with no preprocessing syntax." }
			.joined(separator: "\n\n")
		let tracked = MarkdownPreprocessor.processTrackingOptionalOffsets(source)

		#expect(tracked.processed == source)
		#expect(tracked.map == nil)
	}

	@Test func parserTrackingStillBuildsAMapForStructuralRewrites() {
		let source = "some ==marked== text"
		let tracked = MarkdownPreprocessor.processTrackingOptionalOffsets(source)

		#expect(tracked.processed != source)
		#expect(tracked.map?.count == tracked.processed.utf16.count)
	}

	@Test func cancelledDisplayPreprocessingSkipsObsoleteDocumentWidePasses() async {
		let source = (0..<20_000)
			.map { "Paragraph \($0) with ==highlight==, :smile:, and [[Wiki]]." }
			.joined(separator: "\n")
		let task = Task.detached {
			while !Task.isCancelled { await Task.yield() }
			return MarkdownPreprocessor.process(source)
		}

		task.cancel()
		let processed = await task.value

		// A cancelled synchronous caller gets the untouched input rather than
		// a partially transformed document. Before the cancellation checkpoints
		// this completed every preprocessing pass and returned rewritten text.
		#expect(processed == source)
	}

	@Test func cancelledEditablePreprocessingSkipsOffsetDiffAllocation() async {
		let source = (0..<20_000)
			.map { "Paragraph \($0) with ==highlight== and [[Wiki]]." }
			.joined(separator: "\n")
		let task = Task.detached {
			while !Task.isCancelled { await Task.yield() }
			return MarkdownPreprocessor.processTrackingOptionalOffsets(source)
		}

		task.cancel()
		let tracked = await task.value

		#expect(tracked.processed == source)
		#expect(tracked.map == nil)
	}

	@Test func linearOffsetBuilderPreservesReplaySemantics() {
		let values = (0...6).flatMap { length in
			(0..<(1 << length)).map { bits in
				String((0..<length).map { bits & (1 << $0) == 0 ? "a" : "b" })
			}
		}
		for source in values {
			for processed in values {
				#expect(
					MarkdownPreprocessor.offsetMap(from: source, to: processed)
						== replayingOffsetMap(from: source, to: processed),
					"mapping changed for \(source.debugDescription) → \(processed.debugDescription)")
			}
		}
	}

	@Test func manyDistributedRewritesDoNotMakeOffsetMappingQuadratic() {
		let source = (0..<10_000).map { "#Heading\($0)" }.joined(separator: "\n")
		let processed = source.replacingOccurrences(of: "#Heading", with: "# Heading")
		let clock = ContinuousClock()
		let start = clock.now
		let map = MarkdownPreprocessor.offsetMap(from: source, to: processed)
		let elapsed = start.duration(to: clock.now)

		#expect(map.count == processed.utf16.count)
		#expect(elapsed < .seconds(2), "distributed offset mapping took \(elapsed)")
	}

	@Test func normalParsingDoesNotTouchOptInPerformanceMetrics() {
		let wasEnabled = MarkdownPreprocessor.recordsPerformanceMetrics
		let previousTimings = MarkdownPreprocessor.recordedTimings
		defer {
			MarkdownPreprocessor.recordsPerformanceMetrics = wasEnabled
			MarkdownPreprocessor.recordedTimings = previousTimings
		}
		MarkdownPreprocessor.recordsPerformanceMetrics = false
		MarkdownPreprocessor.recordedTimings = ["sentinel": 1]

		_ = MarkdownBlockParser.parse(
			(0..<1_000)
				.map { "Paragraph \($0) with **formatting**." }
				.joined(separator: "\n\n"),
			trackSourceOffsets: true)

		#expect(MarkdownPreprocessor.recordedTimings == ["sentinel": 1])
	}

	/// The former implementation, retained here as a semantic oracle for a
	/// dense exhaustive matrix of insertions and removals.
	private func replayingOffsetMap(from source: String, to processed: String) -> [Int] {
		let src = Array(source.utf16)
		let dst = Array(processed.utf16)
		if src == dst { return Array(0..<dst.count) }
		var prefix = 0
		while prefix < src.count, prefix < dst.count, src[prefix] == dst[prefix] { prefix += 1 }
		var suffix = 0
		while suffix < src.count - prefix, suffix < dst.count - prefix,
		      src[src.count - 1 - suffix] == dst[dst.count - 1 - suffix] { suffix += 1 }
		let srcMiddle = Array(src[prefix..<(src.count - suffix)])
		let dstMiddle = Array(dst[prefix..<(dst.count - suffix)])
		let diff = dstMiddle.difference(from: srcMiddle)
		var offsets = Array(prefix..<(src.count - suffix))
		for change in diff.removals.reversed() {
			if case let .remove(offset, _, _) = change { offsets.remove(at: offset) }
		}
		for change in diff.insertions {
			if case let .insert(offset, _, _) = change {
				let neighbor = offset > 0 ? offsets[offset - 1]
					: (offset < offsets.count ? offsets[offset] : (prefix > 0 ? prefix - 1 : 0))
				offsets.insert(neighbor, at: offset)
			}
		}
		let shift = src.count - dst.count
		return Array(0..<prefix) + offsets + (dst.count - suffix..<dst.count).map { $0 + shift }
	}
}
