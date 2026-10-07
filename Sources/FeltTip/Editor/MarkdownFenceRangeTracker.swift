//
//  MarkdownFenceRangeTracker.swift
//  FeltTip
//
//  Keeps a raw editor's cached code-fence ranges current across single edits
//  so ordinary typing never runs the fence scan over the whole document. Both
//  raw editors (NSTextView and UITextView) share it.
//

import Foundation

enum MarkdownFenceRangeTracker {
	/// `ranges` shifted and stretched for an edit that replaced `editedRange`
	/// (as reported after the edit, i.e. the inserted text's range) with a net
	/// length change of `delta`. Returns nil when the edit could have changed
	/// fence structure, meaning the caller must rescan with
	/// `MarkdownSyntaxHighlighter.fenceRanges(in:)`.
	static func updating(
		_ ranges: [NSRange], after editedRange: NSRange, delta: Int, in text: NSString
	) -> [NSRange]? {
		var ranges = ranges
		let insertedEnd = min(text.length, editedRange.location + editedRange.length)
		if editedRange.location <= insertedEnd,
		   text.substring(with: NSRange(
			location: editedRange.location,
			length: max(0, insertedEnd - editedRange.location))).contains("`") {
			return nil
		}
		let oldLength = max(0, editedRange.length - delta)
		let oldEnd = editedRange.location + oldLength
		let oldDocumentLength = max(0, text.length - delta)
		for index in ranges.indices {
			let fence = ranges[index]
			let fenceEnd = fence.location + fence.length
			if oldEnd <= fence.location {
				ranges[index].location += delta
			} else if editedRange.location >= fenceEnd {
				// An unterminated final fence reaches EOF. Appending at that
				// exact boundary is still inside the fence, not after it, so
				// extend the cached range without rescanning the document. A
				// closed final fence ends in a line-leading marker and keeps the
				// normal "after" behavior.
				if delta > 0,
				   editedRange.location == fenceEnd,
				   fenceEnd == oldDocumentLength,
				   !endsWithClosingFenceMarker(fence, in: text) {
					ranges[index].length += delta
				}
				continue
			} else if editedRange.location > fence.location + 3,
					  oldEnd < fenceEnd - 3 {
				ranges[index].length += delta
			} else {
				return nil
			}
		}
		return ranges
	}

	private static func endsWithClosingFenceMarker(_ range: NSRange, in text: NSString) -> Bool {
		guard range.length >= 3 else { return false }
		let marker = NSMaxRange(range) - 3
		guard marker + 3 <= text.length,
		      text.character(at: marker) == 0x60,
		      text.character(at: marker + 1) == 0x60,
		      text.character(at: marker + 2) == 0x60 else {
			return false
		}
		return text.lineRange(for: NSRange(location: marker, length: 0)).location == marker
	}
}
