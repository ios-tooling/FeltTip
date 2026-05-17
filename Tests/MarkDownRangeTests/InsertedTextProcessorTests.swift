import Testing
@testable import MarkDownRange

@Suite struct InsertedTextProcessorTests {
	@Test func basicInsertion() {
		#expect(InsertedTextProcessor.process("This is ++inserted++ text.") == "This is <u>inserted</u> text.")
	}

	@Test func multipleSpansOnOneLine() {
		#expect(InsertedTextProcessor.process("a ++one++ b ++two++ c") == "a <u>one</u> b <u>two</u> c")
	}

	@Test func skipsInlineCode() {
		#expect(InsertedTextProcessor.process("see `++raw++` literal") == "see `++raw++` literal")
	}

	@Test func skipsFencedCodeBlocks() {
		let md = """
		```
		++keep++
		```
		++rewrite++
		"""
		let expected = """
		```
		++keep++
		```
		<u>rewrite</u>
		"""
		#expect(InsertedTextProcessor.process(md) == expected)
	}

	@Test func leavesPlusPlusWithSpaceAlone() {
		// `c++ test++` — the leading `++ ` has space immediately after, so the
		// pattern (which requires non-space content) shouldn't match.
		#expect(InsertedTextProcessor.process("c++ test++") == "c++ test++")
	}
}
