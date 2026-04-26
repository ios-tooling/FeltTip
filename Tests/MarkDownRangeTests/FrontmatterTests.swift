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
}
