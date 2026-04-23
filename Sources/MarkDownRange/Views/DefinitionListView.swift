//
//  DefinitionListView.swift
//  MarkDownRange
//

import SwiftUI

struct DefinitionListView: View {
	let items: [DefinitionItem]
	let theme: MarkdownTheme
	let fontSize: CGFloat

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			ForEach(Array(items.enumerated()), id: \.offset) { _, item in
				VStack(alignment: .leading, spacing: 4) {
					Text(item.term)
						.font(.system(size: fontSize, weight: .semibold))
						.foregroundStyle(theme.textColor)

					ForEach(Array(item.definitions.enumerated()), id: \.offset) { _, def in
						Text(def)
							.font(.system(size: fontSize))
							.foregroundStyle(theme.textColor)
							.padding(.leading, 24)
					}
				}
			}
		}
	}
}
