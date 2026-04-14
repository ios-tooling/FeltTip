//
//  MarkdownTheme.swift
//  MarkdownRendering
//

import SwiftUI

public struct MarkdownTheme: Equatable, Sendable {
	public var textColor: Color
	public var linkColor: Color
	public var codeBackground: Color
	public var codeForeground: Color
	public var secondaryColor: Color
	public var backgroundColor: Color

	public init(
		textColor: Color = .primary,
		linkColor: Color = .blue,
		codeBackground: Color = Color(.secondarySystemFill),
		codeForeground: Color = .primary,
		secondaryColor: Color = .secondary,
		backgroundColor: Color = Color(.textBackgroundColor)
	) {
		self.textColor = textColor
		self.linkColor = linkColor
		self.codeBackground = codeBackground
		self.codeForeground = codeForeground
		self.secondaryColor = secondaryColor
		self.backgroundColor = backgroundColor
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
		backgroundColor: .white
	)

	public static let sepia = MarkdownTheme(
		textColor: Color(red: 0.30, green: 0.25, blue: 0.18),
		linkColor: Color(red: 0.55, green: 0.27, blue: 0.07),
		codeBackground: Color(red: 0.93, green: 0.89, blue: 0.82),
		codeForeground: Color(red: 0.30, green: 0.25, blue: 0.18),
		secondaryColor: Color(red: 0.50, green: 0.43, blue: 0.33),
		backgroundColor: Color(red: 0.97, green: 0.94, blue: 0.88)
	)

	public static let dark = MarkdownTheme(
		textColor: Color(red: 0.88, green: 0.88, blue: 0.90),
		linkColor: Color(red: 0.35, green: 0.60, blue: 1.0),
		codeBackground: Color(red: 0.18, green: 0.18, blue: 0.20),
		codeForeground: Color(red: 0.88, green: 0.88, blue: 0.90),
		secondaryColor: Color(red: 0.60, green: 0.60, blue: 0.65),
		backgroundColor: Color(red: 0.13, green: 0.13, blue: 0.15)
	)
}
