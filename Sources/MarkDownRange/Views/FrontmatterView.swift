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
		VStack(alignment: .leading, spacing: 0) {
			Button {
				withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
			} label: {
				HStack(spacing: 6) {
					Image(systemName: "doc.text.below.ecg")
					Text("Metadata")
					Spacer()
					Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
						.font(.caption2)
				}
				.font(.system(.caption, weight: .medium))
				.foregroundStyle(theme.secondaryColor)
			}
			.buttonStyle(.plain)

			if isExpanded {
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
				.padding(.top, 6)
			}
		}
		.padding(8)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(theme.codeBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
	}
}
