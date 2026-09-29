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

	@Test("PDF searchable text preserves exact Unicode")
	func searchableTextPreservesExactUnicode() async throws {
		let unicodeLines = [
			"Καλημέρα κόσμε",
			"مرحبا بالعالم",
			"שלום עולם",
			"こんにちは世界",
		]
		let html = MarkdownHTMLRenderer.renderDocument(
			markdown: "Unicode long target: Καλημέρα κόσμε, Привет мир, こんにちは世界, مرحبا بالعالم, שלום עולם, café, résumé, coöperate, emoji 😀, math-ish x <= y >= z.")
		let data = try #require(await MarkdownPDFRenderer.pdfData(html: html))
		let searchable = try #require(PDFDocument(data: data)?.string)

		for line in unicodeLines {
			#expect(searchable.contains(line), "PDF searchable text must preserve \(line.debugDescription); extracted \(searchable.debugDescription)")
		}
	}
}
