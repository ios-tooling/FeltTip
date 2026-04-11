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
				.fill(theme.secondaryColor.opacity(0.5))
				.frame(width: 4)

			VStack(alignment: .leading, spacing: 8) {
				ForEach(children) { block in
					MarkdownContentView(blocks: [block], theme: theme, fontSize: fontSize, baseURL: baseURL, onLinkHover: onLinkHover)
				}
			}
			.foregroundStyle(theme.secondaryColor)
			.padding(.leading, 12)
		}
	}
}
