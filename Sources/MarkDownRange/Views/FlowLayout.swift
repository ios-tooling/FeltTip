//
//  FlowLayout.swift
//  MarkDownRange
//

import SwiftUI

/// A single-axis flow layout: subviews are placed left-to-right, wrapping to
/// the next row when the running width would exceed the proposed width. Each
/// row is centered horizontally so an underfilled trailing row matches the
/// `<p align="center">` containers that originally wrapped these images.
///
/// Built mainly for `ImageRowView` — the canonical case is a long strip of
/// shield/badge images that needs to wrap on narrow windows instead of
/// overflowing horizontally.
struct FlowLayout: Layout {
	var horizontalSpacing: CGFloat = 8
	var verticalSpacing: CGFloat = 8
	var alignment: HorizontalAlignment = .center

	struct Row {
		var items: [(index: Int, size: CGSize)]
		var width: CGFloat
		var height: CGFloat
	}

	private func computeRows(proposalWidth: CGFloat, subviews: Subviews) -> [Row] {
		var rows: [Row] = [Row(items: [], width: 0, height: 0)]
		for index in subviews.indices {
			let size = subviews[index].sizeThatFits(.unspecified)
			let isFirstInRow = rows[rows.count - 1].items.isEmpty
			let prospectiveWidth = isFirstInRow
				? size.width
				: rows[rows.count - 1].width + horizontalSpacing + size.width
			if prospectiveWidth > proposalWidth, !isFirstInRow {
				rows.append(Row(items: [(index, size)], width: size.width, height: size.height))
			} else {
				rows[rows.count - 1].items.append((index, size))
				rows[rows.count - 1].width = prospectiveWidth
				rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
			}
		}
		return rows
	}

	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		guard !subviews.isEmpty else { return .zero }
		let proposalWidth = proposal.width ?? .infinity
		let rows = computeRows(proposalWidth: proposalWidth, subviews: subviews)
		let height = rows.map(\.height).reduce(0, +)
			+ CGFloat(max(0, rows.count - 1)) * verticalSpacing
		let widest = rows.map(\.width).max() ?? 0
		// Don't claim more width than the proposal — wrapping is the *point* of
		// this layout, so reporting a finite width here keeps SwiftUI from
		// over-allocating space on the parent stack.
		let reportedWidth = proposal.width.map { min(widest, $0) } ?? widest
		return CGSize(width: reportedWidth, height: height)
	}

	func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
		guard !subviews.isEmpty else { return }
		let rows = computeRows(proposalWidth: bounds.width, subviews: subviews)
		var y = bounds.minY
		for row in rows {
			let rowOriginX: CGFloat = {
				switch alignment {
				case .leading: return bounds.minX
				case .trailing: return bounds.maxX - row.width
				default: return bounds.minX + (bounds.width - row.width) / 2
				}
			}()
			var x = rowOriginX
			for item in row.items {
				subviews[item.index].place(
					at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2),
					proposal: ProposedViewSize(item.size)
				)
				x += item.size.width + horizontalSpacing
			}
			y += row.height + verticalSpacing
		}
	}
}
