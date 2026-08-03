import Testing
import SwiftUI
@testable import MarkDownRange

@Suite struct ThemeTests {
	@Test func defaultThemeExists() {
		let theme = MarkdownTheme.default
		#expect(theme == MarkdownTheme())
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
		// Font is intentionally not Equatable; this is a smoke test for both
		// ends of the supported heading-level scale.
		_ = theme.headingFont(level: 1, base: 16)
		_ = theme.headingFont(level: 6, base: 16)
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
