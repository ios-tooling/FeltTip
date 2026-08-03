import Foundation
import Testing
@testable import MarkDownRange

#if os(macOS)
@Suite struct MarkdownLineIndexTests {
	@Test func singleCharacterEditShiftsOnlyTheFollowingStarts() {
		let index = MarkdownLineIndex(text: "one\ntwo\nthree")
		let edited = "one\ntXwo\nthree" as NSString
		index.applyEdit(
			in: edited, editedRange: NSRange(location: 5, length: 1), delta: 1)
		#expect(index.starts == [0, 4, 9])
		#expect(index.position(at: 6) == (2, 3))
	}

	@Test func insertingAndDeletingNewlinesSplicesTheIndex() {
		let index = MarkdownLineIndex(text: "one\ntwo\nthree")
		let inserted = "one\nt\nwo\nthree" as NSString
		index.applyEdit(
			in: inserted, editedRange: NSRange(location: 5, length: 1), delta: 1)
		#expect(index.starts == [0, 4, 6, 9])

		let deleted = "one\ntwo\nthree" as NSString
		index.applyEdit(
			in: deleted, editedRange: NSRange(location: 5, length: 0), delta: -1)
		#expect(index.starts == [0, 4, 8])
		#expect(index.position(at: 10) == (3, 3))
	}

	@Test func replacingMultipleLinesKeepsSortedUTF16Offsets() {
		let index = MarkdownLineIndex(text: "😀 zero\none\ntwo\nthree")
		let replacement = "😀 zero\nONE\nAND\nTWO\nthree" as NSString
		index.applyEdit(
			in: replacement, editedRange: NSRange(location: 8, length: 12), delta: 4)
		#expect(index.starts == [0, 8, 12, 16, 20])
		#expect(index.position(at: 20) == (5, 1))
	}
}
#endif
