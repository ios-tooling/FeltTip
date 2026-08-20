import CoreGraphics
import Foundation
import Testing
@testable import MarkDownRange

/// Does a prerendered mermaid SVG actually *draw* when the document is turned
/// into a PDF? The export path embeds inline SVG (not a base64 `<img>`) because
/// mermaid labels use `<foreignObject>`, which doesn't render in an image — but
/// nothing so far checked that the inline form survives WKWebView's `createPDF`.
@Suite struct MermaidPDFDrawingTests {
	private let doc = """
	# Diagram

	```mermaid
	graph TD
	    A[Source] --> B[Renderer]
	    B --> C[PDF]
	```

	Trailing paragraph.
	"""

	/// Renders `markdown` to PDF and reports the total length of the page
	/// content streams — a proxy for "how much was actually drawn" that doesn't
	/// depend on rasterizing.
	@MainActor
	private func drawnBytes(diagrams: [String: String]) async throws -> Int {
		let html = MarkdownHTMLRenderer.renderDocument(markdown: doc, mermaidDiagrams: diagrams)
		let data = try #require(await MarkdownPDFRenderer.pdfData(html: html))
		let provider = try #require(CGDataProvider(data: data as CFData))
		let document = try #require(CGPDFDocument(provider))
		var total = 0
		for index in 1...max(document.numberOfPages, 1) {
			guard let page = document.page(at: index),
				  let dict = page.dictionary else { continue }
			var stream: CGPDFStreamRef?
			if CGPDFDictionaryGetStream(dict, "Contents", &stream), let stream {
				var format = CGPDFDataFormat.raw
				total += (CGPDFStreamCopyData(stream, &format) as Data?)?.count ?? 0
			}
		}
		return total
	}

	@MainActor
	@Test("A prerendered mermaid diagram adds drawn content to the PDF")
	func diagramDrawsIntoPDF() async throws {
		let sources = MarkdownMermaidPrerender.mermaidSources(in: MarkdownBlockParser.parse(doc))
		let svgs = await MermaidSVGRenderer().renderSVGs(for: sources, theme: "default")
		// The engine has to have produced something, or the rest proves nothing.
		#expect(svgs.count == sources.count)

		let withDiagram = try await drawnBytes(diagrams: svgs)
		let withoutDiagram = try await drawnBytes(diagrams: [:])
		// The raw code block is itself content, so this isn't a huge margin —
		// but a diagram that renders as blank space draws strictly less.
		#expect(withDiagram > withoutDiagram)
	}
}
