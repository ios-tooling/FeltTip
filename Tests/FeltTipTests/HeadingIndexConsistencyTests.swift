import Foundation
import Testing
@testable import FeltTip

struct HeadingIndexConsistencyTests {
	@Test func CRLFQueriesAgreeWithParsedIndex() throws {
		let source = "# One\r\n\r\nbody 😀\r\n\r\n## Two\r\ntext"
		let heading = try #require(MarkdownHeading.parse(from: source).last)
		#expect(MarkdownHeading.heading(atCharacterOffset: (source as NSString).length, in: source)?.id == heading.id)
		#expect(MarkdownHeading.characterRange(for: heading.id, in: source) == heading.sourceRange)
	}
	@Test(arguments: ["~~~\n# Example\n~~~\n\n# Real", "````\n```\n# Example\n```\n````\n\n# Real", "    # Example\n\n# Real"])
	func codeDoesNotEnterHeadingIndex(source: String) {
		#expect(MarkdownHeading.parse(from: source).map(\.text) == ["Real"])
	}
}
