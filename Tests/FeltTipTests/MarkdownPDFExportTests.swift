import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import FeltTip

@Suite @MainActor struct MarkdownPDFExportTests {
	@Test("A lost WebKit PDF callback times out instead of hanging")
	func lostPDFCallbackTimesOut() async {
		do {
			_ = try await MarkdownPDFRenderer.capturePDF(
				timeout: .milliseconds(25),
				start: { _ in })
			Issue.record("Expected the missing callback to time out")
		} catch {
			#expect((error as? URLError)?.code == .timedOut)
		}
	}

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

	@Test("PDF hyperlinks remain clickable")
	func hyperlinksRemainClickable() async throws {
		let html = MarkdownHTMLRenderer.renderDocument(
			markdown: "Read the [documentation](https://example.com/docs?q=1&lang=en)."
		)
		let data = try #require(await MarkdownPDFRenderer.pdfData(html: html))
		let document = try #require(PDFDocument(data: data))
		let page = try #require(document.page(at: 0))
		let action = try #require(
			page.annotations.compactMap { $0.action as? PDFActionURL }.first
		)
		#expect(action.url?.absoluteString == "https://example.com/docs?q=1&lang=en")
	}
}
