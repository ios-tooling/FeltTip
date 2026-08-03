#if os(macOS)
import AppKit
import Testing
@testable import MarkDownRange

@Suite("Instant styled preview")
struct MarkdownInstantPreviewTests {
	@Test @MainActor
	func rendersStyledVisibleContentWithoutMarkdownDelimiters() {
		let rendered = MarkdownInstantPreview.renderForTesting("# Heading\n\nA **bold** [link](https://example.com).")

		#expect(rendered.string.contains("Heading"))
		#expect(rendered.string.contains("A bold link."))
		#expect(!rendered.string.contains("# "))
		#expect(!rendered.string.contains("**"))
		#expect(!rendered.string.contains("](https://"))

		let boldRange = (rendered.string as NSString).range(of: "bold")
		let boldFont = rendered.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont
		#expect(boldFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
	}

	@Test @MainActor
	func retainsSourceOffsetsForSelectionHandoff() {
		let rendered = MarkdownInstantPreview.renderForTesting("Before **selected** after")
		let selectedRange = (rendered.string as NSString).range(of: "selected")
		let sourceOffset = rendered.attribute(
			.markdownSourceOffset, at: selectedRange.location, effectiveRange: nil) as? Int

		#expect(sourceOffset == 9)
	}

	@Test @MainActor
	func representsComplexBlocksWithoutStartingWebKit() {
		let markdown = """
		| A | B |
		|---|---|
		| 1 | 2 |

		```swift
		let value = 1
		```

		![Diagram](diagram.svg)
		"""
		let rendered = MarkdownInstantPreview.renderForTesting(markdown)

		#expect(rendered.string.contains("A   |   B"))
		#expect(rendered.string.contains("let value = 1"))
		#expect(rendered.string.contains("Diagram"))
	}
}
#endif
