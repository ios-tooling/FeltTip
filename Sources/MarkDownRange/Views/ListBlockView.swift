//
//  ListBlockView.swift
//  MarkdownRendering
//

import SwiftUI

struct ListBlockView: View {
	let items: [ListItemContent]
	let ordered: Bool
	let start: Int
	let theme: MarkdownTheme
	let fontSize: CGFloat
	let baseURL: URL?
	let onLinkHover: ((String?) -> Void)?

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			ForEach(Array(items.enumerated()), id: \.offset) { index, item in
				HStack(alignment: .firstTextBaseline, spacing: 6) {
					bulletOrCheckbox(index: index, item: item)
						.frame(minWidth: 20, alignment: .trailing)

					VStack(alignment: .leading, spacing: 4) {
						ForEach(item.blocks) { block in
							MarkdownContentView(blocks: [block], theme: theme, fontSize: fontSize, baseURL: baseURL, onLinkHover: onLinkHover)
						}
					}
				}
			}
		}
		.padding(.leading, 8)
	}

	@ViewBuilder private func bulletOrCheckbox(index: Int, item: ListItemContent) -> some View {
		if let checkbox = item.checkbox {
			Image(systemName: checkbox == .checked ? "checkmark.square.fill" : "square")
				.font(.system(size: fontSize * 0.85))
				.foregroundStyle(checkbox == .checked ? theme.linkColor : theme.secondaryColor)
		} else if ordered {
			Text("\(start + index).")
				.font(.system(size: fontSize))
				.foregroundStyle(theme.secondaryColor)
		} else {
			Text("\u{2022}")
				.font(.system(size: fontSize))
				.foregroundStyle(theme.secondaryColor)
		}
	}
}
