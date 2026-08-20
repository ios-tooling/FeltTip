import Testing
@testable import MarkDownRange

@Suite struct MermaidEmbedTests {
	private let mermaidDoc = "# T\n\n```mermaid\ngraph TD\n  A --> B\n```\n"
	private let plainDoc = "# T\n\n```swift\nlet x = 1\n```\n"

	@Test func embedsEngineOnlyForMermaidDocsWhenRequested() {
		// Safety-critical regardless of the engine: when embedding isn't requested
		// (QuickLook / export path), never embed — that 3 MB payload crashes the
		// QuickLook extension. The mermaid block stays a plain code block.
		let notEmbedded = MarkdownHTMLRenderer.renderDocument(markdown: mermaidDoc, embedMermaidEngine: false)
		#expect(!notEmbedded.contains("mermaid.run("))
		#expect(notEmbedded.contains("language-mermaid"))

		// The embed needs the bundled engine, which `Bundle.module` doesn't surface
		// under `swift test`. Skip the positive cases when it's unavailable; the
		// app/extension load it (verified live).
		guard MermaidResources.engineJS != nil else { return }

		let embedded = MarkdownHTMLRenderer.renderDocument(markdown: mermaidDoc, embedMermaidEngine: true)
		#expect(embedded.contains("mermaid.run("))
		#expect(embedded.contains("mermaid.initialize("))

		// Requested but no mermaid → don't ship the engine.
		let plainEmbedded = MarkdownHTMLRenderer.renderDocument(markdown: plainDoc, embedMermaidEngine: true)
		#expect(!plainEmbedded.contains("mermaid.run("))
	}

	@Test func concurrentResourceReadsAgree() async {
		let snapshots = await withTaskGroup(
			of: (engineCount: Int?, templateCount: Int?).self,
			returning: [(engineCount: Int?, templateCount: Int?)].self
		) { group in
			for _ in 0..<32 {
				group.addTask {
					(
						MermaidResources.engineJS?.utf8.count,
						MermaidResources.html(for: "graph TD; A-->B", theme: "default")?.utf8.count
					)
				}
			}
			var results: [(engineCount: Int?, templateCount: Int?)] = []
			for await snapshot in group { results.append(snapshot) }
			return results
		}

		#expect(Set(snapshots.map(\.engineCount)).count == 1)
		#expect(Set(snapshots.map(\.templateCount)).count == 1)
	}
}
