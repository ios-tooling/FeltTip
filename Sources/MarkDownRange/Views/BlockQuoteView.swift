//
//  BlockQuoteView.swift
//  MarkdownRendering
//

import SwiftUI

struct BlockQuoteView: View {
	let children: [MarkdownBlock]
	let theme: MarkdownTheme
	let fontSize: CGFloat
	let baseURL: URL?
	let onLinkHover: ((String?) -> Void)?

	var body: some View {
		HStack(alignment: .top, spacing: 0) {
			RoundedRectangle(cornerRadius: 2)
				.fill(theme.linkColor.opacity(0.65))
				.frame(width: 4)

			VStack(alignment: .leading, spacing: 8) {
				ForEach(children) { block in
					MarkdownContentView.blockView(for: block, theme: theme, fontSize: fontSize, baseURL: baseURL, onLinkHover: onLinkHover)
				}
			}
			.foregroundStyle(theme.secondaryColor)
			.italic()
			.padding(.vertical, 8)
			.padding(.leading, 12)
			.padding(.trailing, 8)
			.frame(maxWidth: .infinity, alignment: .leading)
		}
		.background(theme.secondaryColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
	}
}
