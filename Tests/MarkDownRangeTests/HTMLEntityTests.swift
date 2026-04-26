import Testing
@testable import MarkDownRange

@Suite struct HTMLEntityTests {
	@Test func decodesNonBreakingSpace() {
		let result = HTMLAttributeParser.decodeEntities("foo&nbsp;bar")
		#expect(result == "foo\u{00A0}bar")
	}

	@Test func decodesCommonNamedEntities() {
		let result = HTMLAttributeParser.decodeEntities("&copy; &mdash; &hellip; &reg; &trade;")
		#expect(result == "© — … ® ™")
	}

	@Test func decodesNumericEntities() {
		#expect(HTMLAttributeParser.decodeEntities("&#8212;") == "—")
		#expect(HTMLAttributeParser.decodeEntities("&#x2014;") == "—")
		#expect(HTMLAttributeParser.decodeEntities("&#x1F44D;") == "👍")
	}

	@Test func decodesAmpersandLast() {
		// &amp;nbsp; should not become a non-breaking space.
		let result = HTMLAttributeParser.decodeEntities("&amp;nbsp;")
		#expect(result == "&nbsp;")
	}

	@Test func leavesUnknownEntitiesAlone() {
		let result = HTMLAttributeParser.decodeEntities("&unknownentity;")
		#expect(result == "&unknownentity;")
	}
}
