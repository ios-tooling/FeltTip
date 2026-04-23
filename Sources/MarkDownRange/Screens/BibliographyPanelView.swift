//
//  BibliographyPanelView.swift
//  MarkDownRange
//

import SwiftUI

struct BibliographyPanelView: View {
	let citations: [Citation]
	@Binding var isExpanded: Bool
	let theme: MarkdownTheme
	let fontSize: CGFloat

	private var noteSize: CGFloat { max(11, fontSize - 2) }

	var body: some View {
		VStack(spacing: 0) {
			Divider()

			Button {
				withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
			} label: {
				HStack(spacing: 6) {
					Image(systemName: "books.vertical")
					Text("Bibliography (\(citations.count))")
					Spacer()
					Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
						.font(.caption2)
				}
				.font(.system(size: noteSize, weight: .medium))
				.padding(.horizontal, 12)
				.padding(.vertical, 8)
				.foregroundStyle(.secondary)
			}
			.buttonStyle(.plain)

			if isExpanded {
				Divider()
				ScrollView {
					VStack(alignment: .leading, spacing: 10) {
						ForEach(citations) { citation in
							HStack(alignment: .top, spacing: 10) {
								Text("\(citation.displayIndex).")
									.font(.system(size: noteSize, design: .monospaced))
									.foregroundStyle(.secondary)
									.frame(minWidth: 24, alignment: .trailing)
								Text(citation.content)
									.font(.system(size: noteSize))
									.foregroundStyle(theme.textColor)
									.textSelection(.enabled)
									.frame(maxWidth: .infinity, alignment: .leading)
							}
							.padding(6)
						}
					}
					.padding(.horizontal, 8)
					.padding(.vertical, 4)
				}
				.frame(maxHeight: 200)
			}
		}
		.background(theme.codeBackground.opacity(0.3))
	}
}
