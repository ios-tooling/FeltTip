//
//  MarkdownTheme+Signature.swift
//  MarkDownRange
//

import SwiftUI

extension MarkdownTheme {
	/// Cheap identity key for memoizing renders. Theme is Equatable but using a
	/// tag avoids comparing Color values per scroll. Must include every field
	/// that influences the rendered output, otherwise an edit that only changes
	/// that field (e.g. fontFamily in the Theme Builder) gets short-circuited by
	/// the render cache.
	var signature: String {
		"\(textColor.hashValue)|\(linkColor.hashValue)|\(codeBackground.hashValue)|\(codeForeground.hashValue)|\(secondaryColor.hashValue)|\(backgroundColor.hashValue)|\(headingColor.hashValue)|\(alternateRowBackground?.hashValue ?? 0)|\(mirrorHighlightColor.hashValue)|\(fontFamily.rawValue)"
	}
}
