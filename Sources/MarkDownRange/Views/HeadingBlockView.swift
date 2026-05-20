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
	/// Horizontal alignment for the heading text and (where applicable) the
	/// trailing divider. Defaults to `.leading` so plain markdown headings
	/// render the same as before; the `.aligned` block wrapper passes
	/// `.center` / `.trailing` through when the source HTML specified one.
	var alignment: HorizontalAlignment = .leading

	private var styledContent: AttributedString {
		var str = content
		str.font = theme.headingFont(level: level, base: fontSize)
		return str
	}

	var body: some View {
		VStack(alignment: alignment, spacing: 6) {
			Text(styledContent)
				.multilineTextAlignment(textAlignment)
				.frame(maxWidth: .infinity, alignment: frameAlignment)
				.textSelection(.enabled)
				.accessibilityAddTraits(.isHeader)

			if level <= 2 {
				Divider().foregroundStyle(theme.secondaryColor.opacity(0.3))
			}
		}
		.padding(.top, topPadding)
		.padding(.bottom, bottomPadding)
		.frame(maxWidth: .infinity, alignment: frameAlignment)
	}

	private var frameAlignment: Alignment {
		Alignment(horizontal: alignment, vertical: .center)
	}

	private var textAlignment: TextAlignment {
		switch alignment {
		case .center: .center
		case .trailing: .trailing
		default: .leading
		}
	}

	private var topPadding: CGFloat {
		switch level {
		case 1: 24
		case 2: 18
		case 3: 14
		default: 10
		}
	}

	private var bottomPadding: CGFloat {
		switch level {
		case 1, 2: 8
		case 3: 6
		default: 4
		}
	}
}
