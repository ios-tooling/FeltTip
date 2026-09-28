//
//  MarkdownBlockDiff.swift
//  FeltTip
//
//  Computes the minimal contiguous block replacement between two rendered
//  fragment lists. A typical edit touches one or two blocks; the prefix is
//  compared by absolute HTML (offsets before the edit haven't moved) and the
//  suffix by offset-relative signature (a single contiguous source edit
//  shifts every later stamp by the same delta).
//

import Foundation

public struct MarkdownBlockPatch: Sendable, Equatable {
	/// Index of the first replaced block, count of old blocks removed, and
	/// the replacement HTML (one string per new block).
	public let start: Int
	public let removeCount: Int
	public let html: [String]
	/// Where the surviving tail's first and last stamped blocks must END UP.
	/// Both anchors must imply the same live delta before the page mutates when
	/// a host-driven update has no exact source delta. Structural edits supply
	/// their exact UTF-16 delta instead. The
	/// PAGE computes that delta from its own live stamps — the coordinator's
	/// fragment baseline can be stale by fast-path typing (which shifted the
	/// live stamps but never re-rendered), so a Swift-computed delta would
	/// double-shift. -1 offset when the tail carries no stamps.
	public let tailAnchorOffset: Int
	public let tailAnchorStamp: Int
	public let tailEndAnchorOffset: Int
	public let tailEndAnchorStamp: Int
	/// Number of blocks the OLD page must have — the patch applier bails to a
	/// full swap when the live DOM disagrees (caret holder spans, unexpected
	/// structure), so a mismatch can never mis-patch.
	public let expectedOldCount: Int
}

public enum MarkdownBlockDiff {
	/// The patch turning `old` into `new`, or nil when a full swap is the
	/// better (or only safe) choice: no change at all, no prior fragments, or
	/// the changed span covering most of the document.
	public static func patch(from old: [MarkdownBlockFragment], to new: [MarkdownBlockFragment]) -> MarkdownBlockPatch? {
		guard !old.isEmpty else { return nil }
		guard old != new else { return nil }
		var prefix = 0
		while prefix < old.count, prefix < new.count, old[prefix].html == new[prefix].html { prefix += 1 }
		var suffix = 0
		while suffix < old.count - prefix, suffix < new.count - prefix,
		      old[old.count - 1 - suffix].signature == new[new.count - 1 - suffix].signature { suffix += 1 }
		let removeCount = old.count - prefix - suffix
		let insertCount = new.count - prefix - suffix
		// A change spanning most of the document isn't worth patching — but a
		// handful of blocks always is, however small the document.
		let span = max(removeCount, insertCount)
		guard span <= 4 || span * 5 <= max(old.count, new.count) * 2 else { return nil }
		var anchorOffset = -1
		var anchorStamp = 0
		var endAnchorOffset = -1
		var endAnchorStamp = 0
		for (index, fragment) in new[(new.count - suffix)...].enumerated() {
			if let stamp = fragment.firstStamp {
				if anchorOffset < 0 {
					anchorOffset = index
					anchorStamp = stamp
				}
				endAnchorOffset = index
				endAnchorStamp = stamp
			}
		}
		return MarkdownBlockPatch(
			start: prefix,
			removeCount: removeCount,
			html: new[prefix..<(new.count - suffix)].map(\.html),
			tailAnchorOffset: anchorOffset,
			tailAnchorStamp: anchorStamp,
			tailEndAnchorOffset: endAnchorOffset,
			tailEndAnchorStamp: endAnchorStamp,
			expectedOldCount: old.count)
	}
}
