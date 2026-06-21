import Testing
@testable import MarkDownRange

@Suite struct MermaidExportTests {
	private let mermaidDoc = "# T\n\n```mermaid\ngraph TD\n  A --> B\n```\n"

	// Key the map off the parser's own source string so it matches what
	// `renderBlock` looks up — exactly the contract the production path relies on.
	private func svgMap(_ svg: String) -> [String: String] {
		let sources = MarkdownMermaidPrerender.mermaidSources(in: MarkdownBlockParser.parse(mermaidDoc))
		return Dictionary(uniqueKeysWithValues: sources.map { ($0, svg) })
	}

	@Test func substitutesPrerenderedSVGForMermaidBlock() {
		let svg = "<svg id=\"diagram\"><g>fake</g></svg>"
		let html = MarkdownHTMLRenderer.renderDocument(markdown: mermaidDoc, mermaidDiagrams: svgMap(svg))
		// The diagram is embedded inline...
		#expect(html.contains(svg))
		#expect(html.contains("class=\"mermaid-diagram\""))
		// ...and the raw mermaid code block is gone.
		#expect(!html.contains("language-mermaid"))
	}

	@Test func leavesRawCodeBlockWhenNoSVGProvided() {
		let html = MarkdownHTMLRenderer.renderDocument(markdown: mermaidDoc)
		#expect(html.contains("language-mermaid"))
		// The CSS always names `.mermaid-diagram`; the body must not use it.
		#expect(!html.contains("class=\"mermaid-diagram\""))
	}

	@Test func extractsNestedMermaidSources() {
		let nested = "- item\n\n  ```mermaid\n  graph TD\n    A --> B\n  ```\n"
		let blocks = MarkdownBlockParser.parse(nested)
		let sources = MarkdownMermaidPrerender.mermaidSources(in: blocks)
		#expect(sources.count == 1)
		#expect(sources.first?.contains("A --> B") == true)
	}
}
