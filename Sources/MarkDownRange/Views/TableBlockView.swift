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

		switch tableAlignment {
		case .fill:
			grid
		case .leading:
			HStack(spacing: 0) {
				grid
				Spacer(minLength: 0)
			}
		case .center:
			HStack(spacing: 0) {
				Spacer(minLength: 0)
				grid
				Spacer(minLength: 0)
			}
		case .trailing:
			HStack(spacing: 0) {
				Spacer(minLength: 0)
				grid
			}
		}
	}

	@ViewBuilder private func cellView(_ cell: TableCell, isHeader: Bool) -> some View {
		let inner = Group {
			switch cell {
			case .text(let content):
				Text(Self.charWrapped(content))
					.textSelection(.enabled)
					.font(isHeader ? .system(.body, weight: .semibold) : nil)
					.fixedSize(horizontal: false, vertical: true)
			case .image(let source, let alt, let link, let width, let height):
				tableCellImage(source: source, alt: alt, link: link, width: width, height: height)
			}
		}
		.padding(8)
		.background(isHeader ? theme.codeBackground : .clear)
		.accessibilityAddTraits(isHeader ? .isHeader : [])
		if tableAlignment == .fill {
			inner.frame(maxWidth: .infinity, alignment: .center)
		} else {
			inner
		}
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
