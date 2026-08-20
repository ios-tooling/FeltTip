//
//  MarkdownTheme.swift
//  MarkdownRendering
//

import SwiftUI
#if os(macOS)
	import AppKit
#else
	import UIKit
#endif

public enum MarkdownFontFamily: String, Codable, CaseIterable, Sendable {
	case system
	case serif
	case rounded
	case mono

	public var label: String {
		switch self {
		case .system:  "System"
		case .serif:   "Serif"
		case .rounded: "Rounded"
		case .mono:    "Mono"
		}
	}

	#if os(macOS)
	public var systemDesign: NSFontDescriptor.SystemDesign {
		switch self {
		case .system:  .default
		case .serif:   .serif
		case .rounded: .rounded
		case .mono:    .monospaced
		}
	}
	#endif
}

public struct MarkdownTheme: Equatable, Sendable {
	public var textColor: Color
	public var linkColor: Color
	public var codeBackground: Color
	public var codeForeground: Color
	public var secondaryColor: Color
	public var backgroundColor: Color
	public var headingColor: Color
	/// Background tint applied to every other body row in tables.
	/// `nil` disables the stripe effect entirely.
	public var alternateRowBackground: Color?
	/// Wash used to mirror the other pane's selection in a split view.
	/// Carries its own opacity — it draws over regular text.
	public var mirrorHighlightColor: Color
	/// Font family used for body and heading text in the rendered output.
	/// Inline code and code blocks always use monospaced regardless of this.
	public var fontFamily: MarkdownFontFamily
	/// Whether links are drawn underlined. Off by default; links still carry
	/// the link color so they remain distinguishable.
	public var underlineLinks: Bool

	/// The page background a theme uses when the caller doesn't pick one.
	/// macOS's `textBackgroundColor` (the white editing surface) has no iOS
	/// counterpart, and `UXColor.defaultBackground` maps to
	/// `windowBackgroundColor` there — too gray for a document page.
	public static var defaultBackgroundColor: Color {
		#if os(macOS)
			Color(nsColor: .textBackgroundColor)
		#else
			Color(uiColor: .systemBackground)
		#endif
	}

	public init(
		textColor: Color = .primary,
		linkColor: Color = .blue,
		codeBackground: Color = Color(.secondarySystemFill),
		codeForeground: Color = .primary,
		secondaryColor: Color = .secondary,
		backgroundColor: Color = MarkdownTheme.defaultBackgroundColor,
		headingColor: Color? = nil,
		alternateRowBackground: Color? = nil,
		mirrorHighlightColor: Color? = nil,
		underlineLinks: Bool = false,
		fontFamily: MarkdownFontFamily = .system
	) {
		self.textColor = textColor
		self.linkColor = linkColor
		self.codeBackground = codeBackground
		self.codeForeground = codeForeground
		self.secondaryColor = secondaryColor
		self.backgroundColor = backgroundColor
		self.headingColor = headingColor ?? linkColor
		self.alternateRowBackground = alternateRowBackground
		self.mirrorHighlightColor = mirrorHighlightColor ?? Color(.sRGB, red: 0.49, green: 0.61, blue: 1.0, opacity: 0.2)
		self.underlineLinks = underlineLinks
		self.fontFamily = fontFamily
	}

	public func headingFont(level: Int, base: CGFloat) -> Font {
		let scales: [CGFloat] = [2.0, 1.5, 1.25, 1.1, 1.0, 0.875]
		let scale = scales[min(level - 1, scales.count - 1)]
		let weight: Font.Weight = level <= 2 ? .bold : .semibold
		return .system(size: base * scale, weight: weight)
	}

	/// Mermaid.js theme name corresponding to this theme.
	public var mermaidTheme: String {
		if self == .dark { return "dark" }
		return "default"
	}

	public static let `default` = MarkdownTheme()

	public static let github = MarkdownTheme(
		textColor: Color(red: 0.14, green: 0.16, blue: 0.19),
		linkColor: Color(red: 0.04, green: 0.41, blue: 0.85),
		codeBackground: Color(red: 0.96, green: 0.97, blue: 0.98),
		codeForeground: Color(red: 0.14, green: 0.16, blue: 0.19),
		secondaryColor: Color(red: 0.34, green: 0.38, blue: 0.42),
		backgroundColor: .white,
		alternateRowBackground: Color(red: 0.97, green: 0.98, blue: 0.99)
	)

	public static let sepia = MarkdownTheme(
		textColor: Color(red: 0.30, green: 0.25, blue: 0.18),
		linkColor: Color(red: 0.55, green: 0.27, blue: 0.07),
		codeBackground: Color(red: 0.93, green: 0.89, blue: 0.82),
		codeForeground: Color(red: 0.30, green: 0.25, blue: 0.18),
		secondaryColor: Color(red: 0.50, green: 0.43, blue: 0.33),
		backgroundColor: Color(red: 0.97, green: 0.94, blue: 0.88),
		alternateRowBackground: Color(red: 0.95, green: 0.92, blue: 0.85),
		fontFamily: .serif
	)

	public static let dark = MarkdownTheme(
		textColor: Color(red: 0.88, green: 0.88, blue: 0.90),
		linkColor: Color(red: 0.35, green: 0.60, blue: 1.0),
		codeBackground: Color(red: 0.18, green: 0.18, blue: 0.20),
		codeForeground: Color(red: 0.88, green: 0.88, blue: 0.90),
		secondaryColor: Color(red: 0.60, green: 0.60, blue: 0.65),
		backgroundColor: Color(red: 0.13, green: 0.13, blue: 0.15),
		alternateRowBackground: Color(red: 0.17, green: 0.17, blue: 0.19)
	)
}
