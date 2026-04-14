//
//  AlertBlockView.swift
//  MarkDownRange
//

import SwiftUI

struct AlertBlockView: View {
	let type: AlertType
	let children: [MarkdownBlock]
	let theme: MarkdownTheme
	let fontSize: CGFloat
	let baseURL: URL?
	let onLinkHover: ((String?) -> Void)?

	var body: some View {
		HStack(alignment: .top, spacing: 0) {
			RoundedRectangle(cornerRadius: 2)
				.fill(type.color)
				.frame(width: 4)

			VStack(alignment: .leading, spacing: 6) {
				Label(type.label, systemImage: type.icon)
					.font(.system(size: fontSize, weight: .semibold))
					.foregroundStyle(type.color)

				ForEach(children) { block in
					MarkdownContentView.blockView(for: block, theme: theme, fontSize: fontSize, baseURL: baseURL, onLinkHover: onLinkHover)
				}
			}
			.padding(.leading, 12)
			.padding(.vertical, 8)
		}
		.padding(4)
		.background(type.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
	}
}
