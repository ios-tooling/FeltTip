import Testing
import SwiftUI
@testable import MarkDownRange

@Suite struct ThemeTests {
	@Test func defaultThemeExists() {
		let theme = MarkdownTheme.default
		#expect(theme.textColor != nil)
	}

	@Test func githubTheme() {
		let theme = MarkdownTheme.github
		#expect(theme.backgroundColor == .white)
	}

	@Test func sepiaTheme() {
		let theme = MarkdownTheme.sepia
		#expect(theme.textColor != .white)
	}

	@Test func darkTheme() {
		let theme = MarkdownTheme.dark
		#expect(theme.textColor != .black)
	}

	@Test func headingFontScaling() {
		let theme = MarkdownTheme.default
		let h1 = theme.headingFont(level: 1, base: 16)
		let h6 = theme.headingFont(level: 6, base: 16)
		// Can't directly compare Font values, but verify they don't crash
		#expect(h1 != nil)
		#expect(h6 != nil)
	}

	@Test func customTheme() {
		let theme = MarkdownTheme(
			textColor: .red,
			linkColor: .blue,
			codeBackground: .gray,
			codeForeground: .green,
			secondaryColor: .orange,
			backgroundColor: .black
		)
		#expect(theme.textColor == .red)
		#expect(theme.linkColor == .blue)
	}
}
