//
//  MarkdownOptions.swift
//  FeltTip
//

import Foundation

/// Per-parse flags that influence how the markdown source is interpreted.
/// Threaded through `MarkdownBlockParser.parse` and the preprocessor so any
/// caller that wants non-default behaviour (a strict CommonMark reading, a
/// looser GitHub-style reading, etc.) can opt in without affecting other
/// consumers in the same process.
public struct MarkdownOptions: Sendable, Equatable {
	/// When `true` (CommonMark default), `#Heading` with no space after the
	/// final `#` is treated as a paragraph, not a heading. When `false`, the
	/// preprocessor inserts the missing space so lenient writers still get a
	/// heading.
	public var headingsRequireSpaceAfterHash: Bool

	public init(headingsRequireSpaceAfterHash: Bool = false) {
		self.headingsRequireSpaceAfterHash = headingsRequireSpaceAfterHash
	}

	public static let `default` = MarkdownOptions()
}
