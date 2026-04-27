//
//  InlineFontTraits.swift
//  MarkDownRange
//
//  A custom AttributedString attribute carrying per-run font traits (bold,
//  italic, monospaced). InlineBuilder writes it; the NSAttributedString
//  converter reads it back to reconstruct the right NSFont. This is how we
//  preserve inline emphasis when bridging SwiftUI's opaque Font values into
//  AppKit's NSFont world.
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
	public static let name = "MarkDownRangeInlineFontTraits"
}

extension AttributeScopes {
	public struct MarkDownRangeAttributes: AttributeScope {
		public let inlineFontTraits: InlineFontTraitsAttribute
	}

	public var markDownRange: MarkDownRangeAttributes.Type { MarkDownRangeAttributes.self }
}

extension AttributeDynamicLookup {
	public subscript<T: AttributedStringKey>(dynamicMember keyPath: KeyPath<AttributeScopes.MarkDownRangeAttributes, T>) -> T {
		return self[T.self]
	}
}
