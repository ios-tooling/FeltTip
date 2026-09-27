import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import FeltTip

@Suite @MainActor struct MarkdownPDFExportTests {
	@Test("Short markdown exports as one PDF page")
	func shortDocumentHasNoBlankTrailingPage() async throws {
		let html = MarkdownHTMLRenderer.renderDocument(
			markdown: """
			# Short document

			A paragraph with **bold** text.

			| Item | Value |
			| --- | ---: |
			| One | 42 |

			- First
			- Second
			"""
		)
		let data = try #require(await MarkdownPDFRenderer.pdfData(html: html))
		let provider = try #require(CGDataProvider(data: data as CFData))
		let document = try #require(CGPDFDocument(provider))
		#expect(document.numberOfPages == 1)
		let searchable = try #require(PDFDocument(data: data)?.string)
		#expect(searchable.contains("Second"), "The final list item must not be clipped")
	}
}
