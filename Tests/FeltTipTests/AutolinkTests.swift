import Testing
import Foundation
@testable import FeltTip

@Suite struct AutolinkTests {
	private func parseLinks(_ md: String) -> [LinkInfo] {
		let blocks = MarkdownBlockParser.parse(md)
		guard case .paragraph(_, let links, _) = blocks.first else { return [] }
		return links
	}

	@Test func angleBracketAutolink() {
		let links = parseLinks("Visit <https://example.com> for info")
		#expect(links.count == 1)
		#expect(links.first?.url == "https://example.com")
	}

	@Test func explicitMarkdownLink() {
		let links = parseLinks("Visit [example](https://example.com) for info")
		#expect(links.count == 1)
		#expect(links.first?.url == "https://example.com")
	}

	@Test func bareURLAutolink() {
		let links = parseLinks("Visit https://example.com for info")
		#expect(links.count == 1)
		#expect(links.first?.url == "https://example.com")
	}

	@Test func emailAutolink() {
		let links = parseLinks("Contact <user@example.com>")
		#expect(links.count == 1)
		#expect(links.first?.url.contains("example.com") == true)
	}

	@Test func multipleLinksInParagraph() {
		let links = parseLinks("[one](https://one.com) and [two](https://two.com)")
		#expect(links.count == 2)
		#expect(links[0].url == "https://one.com")
		#expect(links[1].url == "https://two.com")
	}

	@Test func bareURLDoesNotDuplicateExplicitLink() {
		// An explicit [text](url) should not be double-linked by NSDataDetector
		let links = parseLinks("See [example](https://example.com) here")
		#expect(links.count == 1)
	}

	@Test func multipleBareURLs() {
		let links = parseLinks("Visit https://one.com and https://two.com")
		#expect(links.count == 2)
	}
}
