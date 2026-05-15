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

	@State private var headerHeight: CGFloat = 0
	@State private var bodyRowHeights: [Int: CGFloat] = [:]

	private static let headerDividerHeight: CGFloat = 1.5
	private static let bodyDividerHeight: CGFloat = 1

	var body: some View {
		let grid = Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
			if !header.isEmpty {
				GridRow {
					ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
						cellView(cell, isHeader: true)
					}
				}
				.background(headerHeightProbe)
				Rectangle()
					.fill(theme.secondaryColor.opacity(0.35))
					.frame(height: Self.headerDividerHeight)
			}

			ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
				GridRow {
					ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
						cellView(cell, isHeader: false)
					}
				}
				.background(bodyRowHeightProbe(index: rowIndex))
				if rowIndex < rows.count - 1 {
					Rectangle()
						.fill(theme.secondaryColor.opacity(0.15))
						.frame(height: Self.bodyDividerHeight)
				}
			}
		}
		.background(alignment: .top) { backgroundLayer }
		.onPreferenceChange(HeaderHeightKey.self) { headerHeight = $0 }
		.onPreferenceChange(BodyRowHeightsKey.self) { bodyRowHeights = $0 }
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

	private var backgroundLayer: some View {
		VStack(spacing: 0) {
			if !header.isEmpty {
				theme.codeBackground.frame(height: headerHeight)
				Color.clear.frame(height: Self.headerDividerHeight)
			}
			ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, _ in
				bodyRowBackground(at: rowIndex)
					.frame(height: bodyRowHeights[rowIndex] ?? 0)
				if rowIndex < rows.count - 1 {
					Color.clear.frame(height: Self.bodyDividerHeight)
				}
			}
		}
		.frame(maxWidth: .infinity)
	}

	private var headerHeightProbe: some View {
		GeometryReader { geo in
			Color.clear.preference(key: HeaderHeightKey.self, value: geo.size.height)
		}
	}

	private func bodyRowHeightProbe(index: Int) -> some View {
		GeometryReader { geo in
			Color.clear.preference(key: BodyRowHeightsKey.self, value: [index: geo.size.height])
		}
	}

	@ViewBuilder private func cellView(_ cell: TableCell, isHeader: Bool) -> some View {
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

private struct HeaderHeightKey: PreferenceKey {
	static let defaultValue: CGFloat = 0
	static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
		value = max(value, nextValue())
	}
}

private struct BodyRowHeightsKey: PreferenceKey {
	static let defaultValue: [Int: CGFloat] = [:]
	static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
		value.merge(nextValue(), uniquingKeysWith: { _, new in new })
	}
}
