//
//  TableBlockView.swift
//  MarkdownRendering
//

import SwiftUI

struct TableBlockView: View {
	let header: [TableCell]
	let rows: [[TableCell]]
	let theme: MarkdownTheme
	@Environment(\.tableAlignment) private var tableAlignment

	var body: some View {
		let grid = Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
			if !header.isEmpty {
				GridRow {
					ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
						cellView(cell, isHeader: true, rowBackground: theme.codeBackground)
					}
				}
				Rectangle()
					.fill(theme.secondaryColor.opacity(0.35))
					.frame(height: 1.5)
			}

			ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
				GridRow {
					ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
						cellView(cell, isHeader: false, rowBackground: bodyRowBackground(at: rowIndex))
					}
				}
				Divider()
			}
		}
		.overlay(
			RoundedRectangle(cornerRadius: 4)
				.strokeBorder(theme.secondaryColor.opacity(0.2), lineWidth: 1)
		)
		.fixedSize(horizontal: false, vertical: true)

		switch tableAlignment {
		case .fill:
			grid
				.frame(maxWidth: .infinity, alignment: .leading)
				.frame(maxWidth: .infinity, alignment: tableAlignment.frameAlignment)
		case .leading, .center, .trailing:
			grid
				.frame(maxWidth: .infinity, alignment: tableAlignment.frameAlignment)
		}
	}

	@ViewBuilder private func cellView(_ cell: TableCell, isHeader: Bool, rowBackground: Color) -> some View {
		Group {
			switch cell {
			case .text(let str):
				Text(Self.charWrapped(str))
					.textSelection(.enabled)
					.font(isHeader ? .system(.body, weight: .bold) : nil)
					.foregroundStyle(isHeader ? theme.textColor : .primary)
					.fixedSize(horizontal: false, vertical: true)
			case .image(let source, let alt, let link, let width, let height):
				tableCellImage(source: source, alt: alt, link: link, width: width, height: height)
			}
		}
		.padding(.horizontal, 8)
		.padding(.vertical, isHeader ? 10 : 8)
		.frame(maxWidth: .infinity, alignment: isHeader ? .center : .leading)
		.background(rowBackground)
		.gridCellUnsizedAxes(.horizontal)
		.accessibilityAddTraits(isHeader ? .isHeader : [])
	}

	private func bodyRowBackground(at rowIndex: Int) -> Color {
		guard rowIndex.isMultiple(of: 2) == false,
			  let alternate = theme.alternateRowBackground
		else { return .clear }
		return alternate
	}

	/// Apply char-wrapping line break mode so long unbreakable tokens
	/// (URLs, HTML, dotted identifiers) wrap at character boundaries
	/// instead of pushing the table column wider than the available
	/// reading width.
	private static func charWrapped(_ content: AttributedString) -> AttributedString {
		let nsAttr = NSMutableAttributedString(attributedString: NSAttributedString(content))
		let para = NSMutableParagraphStyle()
		para.lineBreakMode = .byCharWrapping
		let range = NSRange(location: 0, length: nsAttr.length)
		nsAttr.addAttribute(NSAttributedString.Key.paragraphStyle, value: para, range: range)
		return AttributedString(nsAttr)
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
