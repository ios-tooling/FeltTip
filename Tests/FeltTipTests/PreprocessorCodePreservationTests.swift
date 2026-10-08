import Testing
@testable import FeltTip

@Suite struct PreprocessorCodePreservationTests {
	@Test(arguments: [
		"````\n```\n++literal++ ~two~ [[Page]] :smile:\n```\n````",
		"~~~\n```\n++literal++ ~two~ [[Page]] :smile:\n~~~",
		"``++literal++ ~two~ [[Page]] :smile:``",
		"`[[Page]]`",
		"    [[Page]] ++literal++ ~two~",
		"> ```\n> [[Page]] ++literal++\n> ```"
	]) func codeIsVerbatim(source: String) {
		#expect(MarkdownPreprocessor.process(source) == source)
		#expect(MarkdownPreprocessor.processTrackingOffsets(source).processed == source)
	}
}

extension PreprocessorCodePreservationTests {
	@Test func unresolvedReferencesRemainVisible() {
		let source = "Known [@yes] and missing [@no].\n\n[@yes]: Known citation\n\nKnown [^yes] and missing [^no].\n\n[^yes]: Known footnote"
		let output = MarkdownPreprocessor.process(source)
		#expect(output.contains("[@no]"))
		#expect(output.contains("[^no]"))
	}
	@Test func fencedDefinitionsDoNotChangeNotesOutsideCode() {
		let source = "~~~\n[^inside]: example\n[^inside]\n~~~\n\ntext"
		#expect(MarkdownPreprocessor.process(source) == source)
	}
}

extension PreprocessorCodePreservationTests {
	@Test func standaloneProcessorsPreserveCode() {
		let code = "``++literal++ ~two~ [[Page]] :smile: ==word== \"hello\" --``"
		for transform in [InsertedTextProcessor.process, SuperSubProcessor.process, WikilinkProcessor.process,
                    EmojiShortcodes.process, HighlightSyntax.process, SmartQuotes.process, SmartTypography.process] {
			#expect(transform(code) == code)
		}
	}
	@Test func protectedDefinitionExamplesDoNotShiftRealGroups() {
		let source = "~~~\nExample\n: not real\n~~~\n\nTerm\n: real"
		let groups = DefinitionListProcessor.sourceGroups(in: source, baseOffset: 0)
		#expect(groups.count == 1)
		#expect(groups.first?.first?.term == "Term")
	}
}

extension PreprocessorCodePreservationTests {
	@Test func directNoteAPIsIgnoreExamplesAndRetainCodeInContent() {
		let source = "~~~\n[^fake]: example\n[^fake]\n[@fake]: example\n[@fake]\n~~~\n\n[^real] [@real]\n\n[^real]: use `++code++`\n[@real]: read `[[Page]]`"
		let notes = MarkdownFootnote.parse(from: source)
		let citations = Citation.parse(from: source)
		#expect(notes.map(\.id) == ["real"])
		#expect(notes.first?.content == "use `++code++`")
		#expect(citations.map(\.id) == ["real"])
		#expect(citations.first?.content == "read `[[Page]]`")
		#expect(MarkdownFootnote.renderableContent(from: source, footnotes: notes).contains("[^fake]"))
		#expect(Citation.renderableContent(from: source, citations: citations).contains("[@fake]"))
	}
}


extension PreprocessorCodePreservationTests {
	@Test func codeBlockCannotBecomeDefinitionTerm() {
		let source = "~~~\nexample\n~~~\n: definition"
		#expect(MarkdownPreprocessor.process(source) == source)
		#expect(DefinitionListProcessor.process(source) == source)
		let adjacentList = "Term\n: real\n\n~~~\n: example\n~~~"
		let groups = DefinitionListProcessor.sourceGroups(in: adjacentList, baseOffset: 0)
		#expect(groups.count == 1)
		#expect(groups.first?.count == 1)
	}
}
