import Testing
@testable import MarkDownRange

/// Citation preprocessor — Pandoc-style `[@key]` references paired with
/// `[@key]: …` definitions. References are renumbered by first-appearance
/// order and rewritten into superscript links with a `citation://` scheme.
@Suite struct CitationTests {
	@Test func parsesSingleReferenceWithDefinition() {
		let md = """
		As shown in [@smith2020] earlier work was inconclusive.

		[@smith2020]: Smith, J. Title. 2020.
		"""
		let citations = Citation.parse(from: md)
		#expect(citations.count == 1)
		#expect(citations.first?.id == "smith2020")
		#expect(citations.first?.displayIndex == 1)
		#expect(citations.first?.content == "Smith, J. Title. 2020.")
	}

	@Test func renumbersByFirstAppearanceOrder() {
		// Definitions appear in alphabetical order; references appear in a
		// different order. The displayIndex must follow reference order, not
		// definition order.
		let md = """
		First [@beta], then [@alpha], then [@gamma].

		[@alpha]: A.
		[@beta]: B.
		[@gamma]: G.
		"""
		let citations = Citation.parse(from: md)
		let indexed = Dictionary(uniqueKeysWithValues: citations.map { ($0.id, $0.displayIndex) })
		#expect(indexed["beta"] == 1)
		#expect(indexed["alpha"] == 2)
		#expect(indexed["gamma"] == 3)
	}

	@Test func duplicateReferences_shareTheSameIndex() {
		// Re-using `[@smith]` after its first appearance must not allocate a
		// new index; it points at the existing entry.
		let md = """
		[@smith] says one thing; [@smith] says another.

		[@smith]: Smith, J. 2020.
		"""
		let citations = Citation.parse(from: md)
		#expect(citations.count == 1)
		#expect(citations.first?.displayIndex == 1)
	}

	@Test func referenceWithoutDefinition_isDropped() {
		// Spec: an undefined reference produces no citation entry. The body
		// text is left untouched so the reader still sees the source token.
		let md = "Mentions [@undefined] but never defines it."
		let citations = Citation.parse(from: md)
		#expect(citations.isEmpty)
	}

	@Test func definitionsInsideCodeFences_areIgnored() {
		// Anything inside a fenced code block must round-trip verbatim — so
		// a `[@key]: …` line inside the fence is *not* a definition, and a
		// reference whose key is *only* defined inside the fence has no
		// resolvable source.
		let md = """
		Cite [@external] and [@fence_only].

		```
		[@fence_only]: This definition is hidden inside a code fence.
		```

		[@external]: External source.
		"""
		let citations = Citation.parse(from: md)
		let ids = citations.map(\.id)
		#expect(ids == ["external"])
	}

	@Test func renderableContent_replacesReferencesWithSuperscriptLinks() {
		let md = """
		Quoted in [@smith2020].

		[@smith2020]: Smith. 2020.
		"""
		let citations = Citation.parse(from: md)
		let rendered = Citation.renderableContent(from: md, citations: citations)
		// Definition line stripped from the rendered body; reference replaced.
		#expect(!rendered.contains("[@smith2020]: Smith"))
		#expect(rendered.contains("[¹](citation://smith2020)"))
	}

	@Test func renderableContent_withNoCitations_returnsInputVerbatim() {
		// Fast-path guard. Reusing the same input must round-trip exactly.
		let md = "No citations here. Move along."
		#expect(Citation.renderableContent(from: md, citations: []) == md)
	}

	@Test func parseDefinition_recognizesWellFormedLine() {
		let parsed = Citation.parseDefinition("[@key]: Author. Year.")
		#expect(parsed?.key == "key")
		#expect(parsed?.content == "Author. Year.")
	}

	@Test func parseDefinition_rejectsMissingContent() {
		// `[@key]:` with nothing after the colon isn't a usable definition.
		#expect(Citation.parseDefinition("[@key]:") == nil)
	}

	@Test func parseDefinition_rejectsMissingColon() {
		// `[@key]` without `:` is a reference, not a definition.
		#expect(Citation.parseDefinition("[@key] is a reference.") == nil)
	}
}
