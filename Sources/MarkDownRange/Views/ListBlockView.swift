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
	@Environment(\.onCheckboxToggle) private var onCheckboxToggle

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
			let isChecked = checkbox == .checked
			if let onCheckboxToggle, let checkboxIndex = item.checkboxIndex {
				Button {
					onCheckboxToggle(checkboxIndex, !isChecked)
				} label: {
					checkboxImage(isChecked: isChecked)
				}
				.buttonStyle(.plain)
			} else {
				checkboxImage(isChecked: isChecked)
			}
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

	private func checkboxImage(isChecked: Bool) -> some View {
		Image(systemName: isChecked ? "checkmark.square.fill" : "square")
			.font(.system(size: fontSize * 0.85))
			.foregroundStyle(isChecked ? theme.linkColor : theme.secondaryColor)
	}
}
