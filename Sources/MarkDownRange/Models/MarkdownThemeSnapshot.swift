//
//  MarkdownThemeSnapshot.swift
//  MarkDownRange
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// JSON-friendly capture of a `MarkdownTheme`. The recorder bakes one of
/// these into each `.markerSnap` so the replayer can rebuild the exact
/// colors the source render used, instead of falling back to a default
/// theme that drifts on every pixel diff.
public struct MarkdownThemeSnapshot: Codable, Sendable, Equatable {
	public var textColor: ColorComponents
	public var linkColor: ColorComponents
	public var codeBackground: ColorComponents
	public var codeForeground: ColorComponents
	public var secondaryColor: ColorComponents
	public var backgroundColor: ColorComponents
	public var headingColor: ColorComponents
	public var alternateRowBackground: ColorComponents?
	public var fontFamily: String

	public struct ColorComponents: Codable, Sendable, Equatable {
		public var r: Double
		public var g: Double
		public var b: Double
		public var a: Double

		public init(r: Double, g: Double, b: Double, a: Double) {
			self.r = r; self.g = g; self.b = b; self.a = a
		}
	}
}

public extension MarkdownTheme {
	/// Resolve every `Color` into sRGB components so the result can survive
	/// JSON encoding without losing the theme's identity.
	var snapshot: MarkdownThemeSnapshot {
		MarkdownThemeSnapshot(
			textColor: textColor.components,
			linkColor: linkColor.components,
			codeBackground: codeBackground.components,
			codeForeground: codeForeground.components,
			secondaryColor: secondaryColor.components,
			backgroundColor: backgroundColor.components,
			headingColor: headingColor.components,
			alternateRowBackground: alternateRowBackground?.components,
			fontFamily: fontFamily.rawValue
		)
	}

	init(snapshot: MarkdownThemeSnapshot) {
		self.init(
			textColor: snapshot.textColor.color,
			linkColor: snapshot.linkColor.color,
			codeBackground: snapshot.codeBackground.color,
			codeForeground: snapshot.codeForeground.color,
			secondaryColor: snapshot.secondaryColor.color,
			backgroundColor: snapshot.backgroundColor.color,
			headingColor: snapshot.headingColor.color,
			alternateRowBackground: snapshot.alternateRowBackground?.color,
			fontFamily: MarkdownFontFamily(rawValue: snapshot.fontFamily) ?? .system
		)
	}
}

extension Color {
	/// sRGB components for serialization. Asset-catalog and semantic colors
	/// (e.g. `.primary`, `.secondary`) resolve through the platform's
	/// current appearance — for snapshot fidelity, callers should snapshot
	/// the theme on the same appearance the recorder used.
	var components: MarkdownThemeSnapshot.ColorComponents {
		#if canImport(AppKit)
		let resolved = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
		return .init(
			r: Double(resolved.redComponent),
			g: Double(resolved.greenComponent),
			b: Double(resolved.blueComponent),
			a: Double(resolved.alphaComponent)
		)
		#elseif canImport(UIKit)
		var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
		UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
		return .init(r: Double(r), g: Double(g), b: Double(b), a: Double(a))
		#else
		return .init(r: 0, g: 0, b: 0, a: 1)
		#endif
	}
}

extension MarkdownThemeSnapshot.ColorComponents {
	var color: Color {
		Color(.sRGB, red: r, green: g, blue: b, opacity: a)
	}
}
