//
//  FrontmatterView.swift
//  MarkDownRange
//

import SwiftUI

struct FrontmatterView: View {
	let pairs: [(key: String, value: String)]
	let theme: MarkdownTheme
	@State private var isExpanded = true

	var body: some View {
		DisclosureGroup(isExpanded: $isExpanded) {
			Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
				ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
					GridRow {
						Text(pair.key)
							.font(.system(.caption, design: .monospaced, weight: .semibold))
							.foregroundStyle(theme.secondaryColor)
							.gridColumnAlignment(.trailing)
						Text(pair.value)
							.font(.system(.caption))
							.foregroundStyle(theme.textColor)
							.textSelection(.enabled)
							.gridColumnAlignment(.leading)
					}
				}
			}
			.padding(.top, 4)
		} label: {
			Label("Metadata", systemImage: "doc.text.below.ecg")
				.font(.system(.caption, weight: .medium))
				.foregroundStyle(theme.secondaryColor)
		}
		.padding(8)
		.background(theme.codeBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
	}
}
