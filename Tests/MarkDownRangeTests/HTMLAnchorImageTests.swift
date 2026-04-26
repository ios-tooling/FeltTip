import Testing
import Foundation
@testable import MarkDownRange

@Suite struct HTMLAnchorImageTests {
	@Test func standaloneAnchorWrappingImagePreservesLink() {
		let md = #"""
		<a href="https://vshymanskyy.github.io/StandWithUkraine">
			<img src="https://example.com/banner.svg">
		</a>
		"""#
		let blocks = MarkdownBlockParser.parse(md)
		dump(blocks, name: "blocks", maxDepth: 3)
		var foundLink = false
		for block in blocks {
			let inner: MarkdownBlock = {
				if case .aligned(_, let b, _) = block { return b }
				return block
			}()
			if case .imageRow(let images, _) = inner, let img = images.first {
				#expect(img.source == "https://example.com/banner.svg")
				#expect(img.link?.absoluteString == "https://vshymanskyy.github.io/StandWithUkraine")
				foundLink = true
			}
		}
		#expect(foundLink, "Expected linked image, got \(blocks)")
	}
}
