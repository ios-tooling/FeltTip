import Testing
import Foundation
@testable import MarkDownRange

@Suite @MainActor struct MarkdownAttachmentSizeCacheTests {
	private func table(_ cells: [[String]]) -> MarkdownBlock {
		let header = cells[0].map { TableCell.text(AttributedString($0)) }
		let rows = cells.dropFirst().map { row in row.map { TableCell.text(AttributedString($0)) } }
		return .table(header: header, rows: Array(rows), columnAlignments: [.default, .default], id: "t")
	}

	// Two tables with the same column/row count but different cell text wrap to
	// different heights, so they must NOT share a cached height — otherwise the
	// taller one reuses the shorter one's height and clips (the bug this guards).
	@Test func sameShapeTablesWithDifferentTextGetDistinctKeys() {
		let short = table([["Shortcut", "Description"], [":q", "Close"], ["]s", "Next"]])
		let tall = table([
			["Shortcut", "Description"],
			[":set spell spelllang=en_us", "Turn on US English spell checking with a long wrapping description"],
			["zu", "Suggest words for the bad word under the cursor from the spellfile"],
		])
		let a = MarkdownAttachmentSizeCache.key(for: short, fontSize: 16, width: 400)
		let b = MarkdownAttachmentSizeCache.key(for: tall, fontSize: 16, width: 400)
		#expect(a != nil)
		#expect(b != nil)
		#expect(a != b)
	}

	// Genuinely identical tables still share a key so the cache keeps working.
	@Test func identicalTablesShareAKey() {
		let one = table([["Shortcut", "Description"], [":q", "Close file"]])
		let two = table([["Shortcut", "Description"], [":q", "Close file"]])
		#expect(MarkdownAttachmentSizeCache.key(for: one, fontSize: 16, width: 400)
			== MarkdownAttachmentSizeCache.key(for: two, fontSize: 16, width: 400))
	}

	// Code blocks have the same hazard: equal line counts, different wrapping.
	@Test func sameLineCountCodeBlocksWithDifferentTextGetDistinctKeys() {
		let short = MarkdownBlock.codeBlock(code: "let x = 1", language: "swift", id: "c1")
		let long = MarkdownBlock.codeBlock(
			code: "let message = \"a deliberately very long single line that wraps to several visual rows\"",
			language: "swift", id: "c2")
		#expect(MarkdownAttachmentSizeCache.key(for: short, fontSize: 16, width: 400)
			!= MarkdownAttachmentSizeCache.key(for: long, fontSize: 16, width: 400))
	}
}
