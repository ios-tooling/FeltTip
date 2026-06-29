import Testing
@testable import MarkDownRange

@Suite struct FrontmatterTests {
	@Test func parsesFrontmatter() {
		let md = "---\ntitle: Hello\nauthor: Ben\n---\n\n# Content"
		let blocks = MarkdownBlockParser.parse(md)
		guard case .frontmatter(let pairs, _) = blocks.first else {
			Issue.record("Expected frontmatter, got \(blocks.first.debugDescription)"); return
		}
		#expect(pairs.count == 2)
		#expect(pairs[0].key == "title")
		#expect(pairs[0].value == "Hello")
		#expect(pairs[1].key == "author")
		#expect(pairs[1].value == "Ben")
	}

	@Test func frontmatterFollowedByContent() {
		let md = "---\ntitle: Test\n---\n\n# Heading"
		let blocks = MarkdownBlockParser.parse(md)
		#expect(blocks.count >= 2)
		if case .frontmatter = blocks[0] {} else { Issue.record("First should be frontmatter") }
		if case .heading = blocks[1] {} else { Issue.record("Second should be heading") }
	}

	@Test func noFrontmatter() {
		let md = "# Just a heading"
		let blocks = MarkdownBlockParser.parse(md)
		let hasFrontmatter = blocks.contains { if case .frontmatter = $0 { return true }; return false }
		#expect(!hasFrontmatter)
	}

	@Test func frontmatterWithTags() {
		let md = "---\ntitle: Post\ntags: [swift, markdown]\ndate: 2026-04-10\n---\n\nBody"
		let blocks = MarkdownBlockParser.parse(md)
		guard case .frontmatter(let pairs, _) = blocks.first else {
			Issue.record("Expected frontmatter"); return
		}
		#expect(pairs.count == 3)
		#expect(pairs[1].key == "tags")
		#expect(pairs[1].value == "[swift, markdown]")
	}

	@Test func frontmatterClosedWithDots() {
		let md = "---\ntitle: Hello\nauthor: Ben\n...\n\n# Content"
		let blocks = MarkdownBlockParser.parse(md)
		guard case .frontmatter(let pairs, _) = blocks.first else {
			Issue.record("Expected frontmatter, got \(blocks.first.debugDescription)"); return
		}
		#expect(pairs.count == 2)
		#expect(pairs[0].key == "title")
		#expect(pairs[1].key == "author")
		if case .heading = blocks.dropFirst().first {} else { Issue.record("Body heading should follow frontmatter") }
	}

	@Test func frontmatterNotInMiddle() {
		let md = "# Title\n\n---\ntitle: Not frontmatter\n---"
		let blocks = MarkdownBlockParser.parse(md)
		let hasFrontmatter = blocks.contains { if case .frontmatter = $0 { return true }; return false }
		#expect(!hasFrontmatter, "--- in the middle should not be parsed as frontmatter")
	}

	/// sample.md opens with `---\n__Advertisement :)__\n…\n---`. That's prose
	/// flanked by thematic breaks, not YAML frontmatter. The old detector
	/// greedily ate the whole intro because lines happened to contain a colon.
	@Test func proseBetweenDashesIsNotFrontmatter() {
		let md = """
		---
		__Advertisement :)__

		- [pica](https://example.com)
		---

		# Heading
		"""
		let blocks = MarkdownBlockParser.parse(md)
		let hasFrontmatter = blocks.contains { if case .frontmatter = $0 { return true }; return false }
		#expect(!hasFrontmatter, "Prose between --- fences should not be parsed as frontmatter")
	}

	@Test func indentedContinuationAccepted() {
		let md = """
		---
		tags:
		  - swift
		  - ios
		title: Post
		---
		"""
		let blocks = MarkdownBlockParser.parse(md)
		guard case .frontmatter(let pairs, _) = blocks.first else {
			Issue.record("Expected frontmatter"); return
		}
		#expect(pairs.count == 2)
		#expect(pairs[0].key == "tags")
		#expect(pairs[1].key == "title")
	}

	@Test func emptyFenceRejected() {
		let blocks = MarkdownBlockParser.parse("---\n\n---")
		let hasFrontmatter = blocks.contains { if case .frontmatter = $0 { return true }; return false }
		#expect(!hasFrontmatter)
	}

	@Test func keyMustStartWithLetter() {
		let md = "---\n__weird__: value\n---"
		let blocks = MarkdownBlockParser.parse(md)
		let hasFrontmatter = blocks.contains { if case .frontmatter = $0 { return true }; return false }
		#expect(!hasFrontmatter)
	}

	/// A skill-style `name`/`description` document whose description packs in
	/// punctuation, parens, quotes, and arrows — none of which should derail the
	/// key:value parse (the key is taken at the first colon, the value is not
	/// validated).
	@Test func parsesNameDescriptionWithRichValue() throws {
		let md = """
		---
		name: build-and-review
		description: Implement a feature, then loop fix→re-review until no required (BLOCKER/SHOULD-FIX) changes remain. Use when the user says "build this and review it".
		---

		# Build and Review
		"""
		let blocks = MarkdownBlockParser.parse(md)
		guard case .frontmatter(let pairs, _) = blocks.first else {
			Issue.record("Expected frontmatter card, got \(blocks.first.debugDescription)"); return
		}
		#expect(pairs.count == 2)
		#expect(pairs[0].key == "name")
		#expect(pairs[0].value == "build-and-review")
		#expect(pairs[1].key == "description")
		#expect(pairs[1].value.hasPrefix("Implement a feature"))
	}

	/// Regression: the styled-text editor parses with `trackSourceOffsets`, which
	/// once swapped the card for a raw `---…---` paragraph dumped into the body.
	/// Frontmatter must render as the card in editable mode too.
	@Test func frontmatterIsCardWhenTrackingOffsets() throws {
		let md = "---\nname: build-and-review\ndescription: Loops fix→review.\n---\n\n# Heading"
		let blocks = MarkdownBlockParser.parse(md, trackSourceOffsets: true)
		guard case .frontmatter(let pairs, _) = blocks.first else {
			Issue.record("Expected frontmatter card in tracking mode, got \(blocks.first.debugDescription)"); return
		}
		#expect(pairs.map(\.key) == ["name", "description"])
		// And the body must not contain stray thematic breaks from un-stripped fences.
		let thematicBreaks = blocks.filter { if case .thematicBreak = $0 { return true }; return false }
		#expect(thematicBreaks.isEmpty, "frontmatter fences must be stripped, not rendered as horizontal rules")
	}
}
