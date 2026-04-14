//
//  DetailsBlockView.swift
//  MarkdownRendering
//

import SwiftUI

struct DetailsBlockView: View {
	let summary: String
	let children: [MarkdownBlock]
	let theme: MarkdownTheme
	let fontSize: CGFloat
	let baseURL: URL?
	let onLinkHover: ((String?) -> Void)?
	@State private var isExpanded = false

	var body: some View {
		DisclosureGroup(isExpanded: $isExpanded) {
			VStack(alignment: .leading, spacing: 8) {
				ForEach(children) { block in
					MarkdownContentView.blockView(for: block, theme: theme, fontSize: fontSize, baseURL: baseURL, onLinkHover: onLinkHover)
				}
			}
			.padding(.top, 4)
		} label: {
			Text(summary)
				.font(.system(size: fontSize, weight: .medium))
		}
		.padding(8)
		.background(theme.codeBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
	}
}
