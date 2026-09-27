//
//  MarkdownLineChanges.swift
//  FeltTip
//

import SwiftUI

/// Per-line change indicators supplied by the host (e.g. a git diff against
/// the committed version). Rendered as colored gutter bars in the raw editor
/// and left-edge markers in the styled web view.
public struct MarkdownLineChanges: Equatable, Sendable {
	public enum Kind: Equatable, Sendable {
		case added, modified
	}

	/// A contiguous run of same-kind changed text, as a UTF-16 offset range
	/// of the current source.
	public struct ChangedRange: Equatable, Sendable {
		public let range: Range<Int>
		public let kind: Kind

		public init(range: Range<Int>, kind: Kind) {
			self.range = range
			self.kind = kind
		}
	}

	/// 0-based hard-line index of the current source → change kind.
	public let changedLines: [Int: Kind]
	/// Line indices after which baseline content was deleted; -1 marks a
	/// deletion before the first line.
	public let deletionsAfter: Set<Int>
	public let changedRanges: [ChangedRange]
	/// UTF-16 offsets anchoring each deletion in offset-addressed views.
	public let deletionOffsets: [Int]

	public init(
		changedLines: [Int: Kind],
		deletionsAfter: Set<Int>,
		changedRanges: [ChangedRange],
		deletionOffsets: [Int]
	) {
		self.changedLines = changedLines
		self.deletionsAfter = deletionsAfter
		self.changedRanges = changedRanges
		self.deletionOffsets = deletionOffsets
	}
}

private struct MarkdownLineChangesKey: EnvironmentKey {
	static let defaultValue: MarkdownLineChanges? = nil
}

public extension EnvironmentValues {
	/// Change indicators shown in the editor gutter and at the styled view's
	/// leading edge; nil hides them.
	var markdownLineChanges: MarkdownLineChanges? {
		get { self[MarkdownLineChangesKey.self] }
		set { self[MarkdownLineChangesKey.self] = newValue }
	}
}
