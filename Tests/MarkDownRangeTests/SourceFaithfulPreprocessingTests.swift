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
}
