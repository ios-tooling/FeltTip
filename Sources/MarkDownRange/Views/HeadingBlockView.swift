//
//  HeadingBlockView.swift
//  MarkdownRendering
//

import SwiftUI

struct HeadingBlockView: View {
	let level: Int
	let content: AttributedString
	let theme: MarkdownTheme
	let fontSize: CGFloat

	private var styledContent: AttributedString {
		var str = content
		str.font = theme.headingFont(level: level, base: fontSize)
		return str
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(styledContent)
				.textSelection(.enabled)

			if level <= 2 {
				Divider().foregroundStyle(theme.secondaryColor.opacity(0.3))
			}
		}
		.padding(.top, level == 1 ? 16 : 8)
	}
}
