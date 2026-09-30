#if os(macOS)
#if os(macOS)
	import AppKit
#else
	import UIKit
#endif
import Testing
@testable import FeltTip

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

	@Test @MainActor
	func resolvesReferenceLinksInsideDefinitionLists() {
		let markdown = "Term\n: Read the [documentation][docs].\n\n[docs]: https://example.com/docs"
		let rendered = MarkdownInstantPreview.renderForTesting(markdown)
		let linkRange = (rendered.string as NSString).range(of: "documentation")

		#expect(rendered.string.contains("Read the documentation."))
		#expect(!rendered.string.contains("[documentation][docs]"))
		#expect(rendered.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL
			== URL(string: "https://example.com/docs"))
		#expect(rendered.attribute(
			.markdownSourceOffset, at: linkRange.location, effectiveRange: nil) as? Int == 17)
	}

	@Test @MainActor
	func resolvesRelativeLinksAgainstRemoteBaseURL() {
		let baseURL = URL(string: "https://example.com/guides/topic/")!
		let rendered = MarkdownInstantPreview.renderForTesting(
			"Read the [sibling](sibling.md).",
			baseURL: baseURL)
		let linkRange = (rendered.string as NSString).range(of: "sibling")

		#expect(rendered.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL
			== URL(string: "https://example.com/guides/topic/sibling.md"))
	}

	@Test @MainActor
	func launchRendererProvidesReadableSelectableTextWithoutFullParse() {
		let rendered = MarkdownInstantPreview.renderLaunchForTesting(
			"# Heading\n\n- A **fast** item\n\n```swift\nlet value = 1\n```")

		#expect(rendered.string.contains("Heading"))
		#expect(rendered.string.contains("• A fast item"))
		#expect(rendered.string.contains("let value = 1"))
		#expect(!rendered.string.contains("# Heading"))
		#expect(!rendered.string.contains("**"))
		let headingRange = (rendered.string as NSString).range(of: "Heading")
		let headingFont = rendered.attribute(
			.font, at: headingRange.location, effectiveRange: nil) as? NSFont
		#expect(headingFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
	}
}
#endif
