import Testing
@testable import FeltTip

@Suite struct LinkReferenceTests {
	private func parseLinks(_ md: String) -> [LinkInfo] {
		let blocks = MarkdownBlockParser.parse(md)
		guard case .paragraph(_, let links, _) = blocks.first else { return [] }
		return links
	}

	@Test func fullReferenceLink() {
		let md = """
		[Click here][example]

		[example]: https://example.com
		"""
		let links = parseLinks(md)
		#expect(links.count >= 1)
		#expect(links.first?.url == "https://example.com")
	}

	@Test func collapsedReferenceLink() {
		let md = """
		[example][]

		[example]: https://example.com
		"""
		let links = parseLinks(md)
		#expect(links.count >= 1)
		#expect(links.first?.url == "https://example.com")
	}

	@Test func shortcutReferenceLink() {
		let md = """
		[example]

		[example]: https://example.com
		"""
		let links = parseLinks(md)
		#expect(links.count >= 1)
		#expect(links.first?.url == "https://example.com")
	}

	@Test func multipleReferences() {
		let md = """
		Visit [Google][g] and [Apple][a].

		[g]: https://google.com
		[a]: https://apple.com
		"""
		let links = parseLinks(md)
		#expect(links.count == 2)
	}

	@Test func referenceWithTitle() {
		let md = """
		[Click][ref]

		[ref]: https://example.com "Example Title"
		"""
		let links = parseLinks(md)
		#expect(links.count >= 1)
		#expect(links.first?.url == "https://example.com")
	}

	@Test func multilineReferenceWithTitle() {
		let md = """
		[Click][ref]

		[ref]:
		  https://example.com
		  "Example Title"
		"""
		let links = parseLinks(md)
		#expect(links.count == 1)
		#expect(links.first?.url == "https://example.com")
		#expect(SmartQuotes.process(md).contains("\"Example Title\""))
	}
}
