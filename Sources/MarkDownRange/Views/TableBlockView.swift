//
//  TableBlockView.swift
//  MarkdownRendering
//

import SwiftUI

struct TableBlockView: View {
	let header: [AttributedString]
	let rows: [[AttributedString]]
	let theme: MarkdownTheme

	var body: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
				if !header.isEmpty {
					GridRow {
						ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
							Text(cell)
								.font(.system(.body, weight: .semibold))
								.padding(8)
								.frame(maxWidth: .infinity, alignment: .leading)
								.background(theme.codeBackground)
						}
					}
				}

				ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
					GridRow {
						ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
							Text(cell)
								.textSelection(.enabled)
								.padding(8)
								.frame(maxWidth: .infinity, alignment: .leading)
						}
					}
					Divider()
				}
			}
		}
		.overlay(
			RoundedRectangle(cornerRadius: 4)
				.strokeBorder(theme.secondaryColor.opacity(0.2), lineWidth: 1)
		)
	}
}
