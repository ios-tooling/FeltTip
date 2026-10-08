import Foundation
import Testing
@testable import FeltTip

@Suite struct HTMLConversionRegressionTests {
	@Test(arguments: ["\n", "\r\n"])
	func frontmatterDoesNotCountAsLink(newline: String) {
		let prefix = "\n---\nexample: \"[metadata](https://old.com)\"\n---\n\n"
			.replacingOccurrences(of: "\n", with: newline)
		let source = prefix + "😀 [first](https://old.com) [second](https://old.com)"
		#expect(MarkdownLinkRewriter.replacingDestination(in: source, currentURL: "https://old.com", occurrence: 1, with: "https://new.com")
			== prefix + "😀 [first](https://old.com) [second](https://new.com)")
	}

	@Test func referenceLinkIgnoresMetadataDefinition() {
		let prefix = "---\nexample: |\n  [id]: https://old.com\n---\n\n"
		let source = prefix + "[visible][id]\n\n[id]: https://old.com"
		#expect(MarkdownLinkRewriter.replacingDestination(in: source, currentURL: "https://old.com", occurrence: 0, with: "https://new.com")
			== prefix + "[visible][id]\n\n[id]: https://new.com")
	}

	@Test func paragraphGapsPreserveOrderAndImages() {
		let blocks = MarkdownBlockParser.parse("<div>Before<p>Middle</p>Between<p>Next</p>After<img src=\"tail.png\"></div>")
		let pieces = blocks.compactMap { block -> String? in
			switch block {
			case .paragraph(let content, _, _): String(content.characters)
			case .image(let source, _, _, _, _): source
			default: nil
			}
		}
		#expect(pieces == ["Before", "Middle", "Between", "Next", "After", "tail.png"])
	}

	@Test(arguments: ["&amp;", "&#38;", "&#x26;", "&#X26;"])
	func URLAttributesAreDecoded(entity: String) {
		let encoded = "https://site.test/?a=1\(entity)b=2"
		let decoded = "https://site.test/?a=1&b=2"
		let blocks = MarkdownBlockParser.parse("<p><a href=\"\(encoded)\">Link</a><img src=\"\(encoded)\"></p>")
		#expect(blocks.count == 2)
		guard case .paragraph(_, let links, _) = blocks.first,
		      case .image(let source, _, _, _, _) = blocks.last else {
			Issue.record("Expected a link paragraph followed by an image")
			return
		}
		#expect(links.first?.url == decoded)
		#expect(source == decoded)
		let rendered = MarkdownHTMLRenderer.renderBlocks(blocks)
		#expect(rendered.contains("a=1&amp;b=2"))
		#expect(!rendered.contains("&amp;amp;"))
		let linked = HTMLAttributeParser.extractLinkedImage(from: "<a href=\"\(encoded)\"><img src=\"\(encoded)\"></a>")
		#expect(linked?.href == decoded)
		#expect(linked?.src == decoded)
		#expect(HTMLAttributeParser.extractImage(from: "<img src=\"\(encoded)\">")?.src == decoded)
		#expect(HTMLAttributeParser.extractLink(from: "<a href=\"\(encoded)\">Link</a>")?.href == decoded)
	}

	@Test(arguments: ["&amp;amp;", "&#38;amp;", "&#x26;amp;"])
	func entitiesDecodeOnlyOnce(encoded: String) {
		#expect(HTMLAttributeParser.decodeEntities(encoded) == "&amp;")
		let hits = ImageRegions.collect(in: "<a href=\"https://site.test/?q=\(encoded)\"><img src=\"image?q=\(encoded)\"></a>")
		#expect(hits.first?.src == "image?q=&amp;")
		#expect(hits.first?.link == "https://site.test/?q=&amp;")
	}
}
