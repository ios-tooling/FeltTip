import Testing
@testable import MarkDownRange

@Suite struct SuperSubProcessorTests {
	@Test func subscriptUnicodeWhenAllMappable() {
		#expect(SuperSubProcessor.process("H~2~O") == "H₂O")
	}

	@Test func superscriptUnicodeWhenAllMappable() {
		#expect(SuperSubProcessor.process("x^2^") == "x²")
	}

	@Test func subscriptFallsBackToHTMLForUnmappableChars() {
		// Capital `H` has no Unicode subscript — used to silently leave the
		// tildes as plain text. Now we emit `<sub>` so the inline builder
		// renders it with a lowered baseline.
		#expect(SuperSubProcessor.process("text ~Hello~ text") == "text <sub>Hello</sub> text")
	}

	@Test func superscriptFallsBackToHTMLForUnmappableChars() {
		#expect(SuperSubProcessor.process("text ^Big^ text") == "text <sup>Big</sup> text")
	}

	@Test func preservesGFMStrikethrough() {
		// `~~strike~~` must NOT be split open into `~ₛₜᵣᵢₖₑ~` — it's a GFM
		// strikethrough that swift-markdown parses downstream.
		#expect(SuperSubProcessor.process("~~strike~~") == "~~strike~~")
	}

	@Test func skipsFencedCodeBlocks() {
		let md = """
		```
		H~2~O
		```
		H~2~O
		"""
		let expected = """
		```
		H~2~O
		```
		H₂O
		"""
		#expect(SuperSubProcessor.process(md) == expected)
	}

	@Test func skipsInlineCode() {
		#expect(SuperSubProcessor.process("Use `H~2~O` literal") == "Use `H~2~O` literal")
	}

	@Test func leavesUnclosedMarkerAlone() {
		#expect(SuperSubProcessor.process("loose ~text") == "loose ~text")
	}

	@Test func rejectsOpeningWithSpace() {
		// `~ text~` shouldn't match — looks like a stray tilde, not subscript.
		#expect(SuperSubProcessor.process("~ text~") == "~ text~")
	}

	@Test func superAndSubscriptSurviveHTMLRenderingForTheStyledPane() {
		let html = MarkdownHTMLRenderer.renderDocument(
			markdown: "Use ^Big^ and ~Hello~",
			includeSourceOffsets: true)
		#expect(html.contains("<sup>Big</sup>"))
		#expect(html.contains("<sub>Hello</sub>"))
	}
}
