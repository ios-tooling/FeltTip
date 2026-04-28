//
//  TableBlockView.swift
//  MarkdownRendering
//

import SwiftUI

struct TableBlockView: View {
	let header: [TableCell]
	let rows: [[TableCell]]
	let theme: MarkdownTheme

	var body: some View {
		Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
			if !header.isEmpty {
				GridRow {
					ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
						cellView(cell, isHeader: true)
					}
				}
			}

			ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
				GridRow {
					ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
						cellView(cell, isHeader: false)
					}
				}
				Divider()
			}
		}
		.overlay(
			RoundedRectangle(cornerRadius: 4)
				.strokeBorder(theme.secondaryColor.opacity(0.2), lineWidth: 1)
		)
	}

	@ViewBuilder private func cellView(_ cell: TableCell, isHeader: Bool) -> some View {
		Group {
			switch cell {
			case .text(let content):
				Text(content)
					.textSelection(.enabled)
					.font(isHeader ? .system(.body, weight: .semibold) : nil)
			case .image(let source, let alt, let link, let width, let height):
				tableCellImage(source: source, alt: alt, link: link, width: width, height: height)
			}
		}
		.padding(8)
		.frame(maxWidth: .infinity, alignment: .center)
		.background(isHeader ? theme.codeBackground : .clear)
		.accessibilityAddTraits(isHeader ? .isHeader : [])
	}

	@ViewBuilder private func tableCellImage(source: String, alt: String, link: URL?, width: CGFloat?, height: CGFloat?) -> some View {
		let image = AsyncImage(url: URL(string: source)) { phase in
			switch phase {
			case .success(let img):
				img.resizable().aspectRatio(contentMode: .fit)
			case .failure:
				Text(alt.isEmpty ? "Image" : alt)
					.font(.caption)
					.foregroundStyle(theme.secondaryColor)
			default:
				ProgressView().controlSize(.small)
			}
		}
		.frame(maxWidth: width ?? 160, maxHeight: height ?? 80)

		if let link {
			SwiftUI.Link(destination: link) { image }
		} else {
			image
		}
	}
}
