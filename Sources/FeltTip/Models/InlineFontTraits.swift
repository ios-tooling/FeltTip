//
//  InlineFontTraits.swift
//  FeltTip
//
//  Per-run font traits (bold, italic, monospaced). Parsed inline content
//  carries them as `InlineStyle` flags; the AttributedString attribute here
//  is written by `InlineContent.attributedString(theme:fontSize:)` for hosts
//  that display inline content with SwiftUI text, so the NSAttributedString
//  converter can reconstruct the right NSFont from SwiftUI's opaque Font.
//

import Foundation

public struct InlineFontTraits: OptionSet, Hashable, Sendable, Codable {
	public let rawValue: UInt8

	public init(rawValue: UInt8) { self.rawValue = rawValue }

	public static let bold = InlineFontTraits(rawValue: 1 << 0)
	public static let italic = InlineFontTraits(rawValue: 1 << 1)
	public static let monospaced = InlineFontTraits(rawValue: 1 << 2)
}

public enum InlineFontTraitsAttribute: AttributedStringKey {
	public typealias Value = InlineFontTraits
	public static let name = "FeltTipInlineFontTraits"
}

extension AttributeScopes {
	public struct FeltTipAttributes: AttributeScope {
		public let inlineFontTraits: InlineFontTraitsAttribute
		public let markdownSourceOffset: MarkdownSourceOffsetAttribute
		public let markdownEscapedPipeSourceOffset: MarkdownEscapedPipeSourceOffsetAttribute
	}

	public var feltTip: FeltTipAttributes.Type { FeltTipAttributes.self }
}

extension AttributeDynamicLookup {
	public subscript<T: AttributedStringKey>(dynamicMember keyPath: KeyPath<AttributeScopes.FeltTipAttributes, T>) -> T {
		return self[T.self]
	}
}
