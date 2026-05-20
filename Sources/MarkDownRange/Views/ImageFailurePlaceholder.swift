//
//  ImageFailurePlaceholder.swift
//  MarkDownRange
//

import SwiftUI

/// Stand-in shown in place of an image that failed to load. Mirrors the
/// "broken image" affordance browsers use: a bordered rectangle at the
/// requested size, with the alt text and a warning icon so the reader knows
/// what was supposed to be there.
struct ImageFailurePlaceholder: View {
	let alt: String
	/// Width/height hints from the source markdown (`<img width=… height=…>`).
	/// Each is honored independently — a width-only image gets the width
	/// reserved and the height sized to fit the alt label, matching a
	/// browser's default broken-image affordance.
	let width: CGFloat?
	let height: CGFloat?

	var body: some View {
		HStack(spacing: 6) {
			Image(systemName: "photo")
				.font(.system(size: 12))
				.foregroundStyle(Color.secondary)
			if !alt.isEmpty {
				Text(alt)
					.font(.footnote)
					.foregroundStyle(Color.secondary)
					.lineLimit(1)
					.truncationMode(.tail)
			}
		}
		.padding(.horizontal, 8)
		.padding(.vertical, 4)
		.frame(width: width, height: height, alignment: .leading)
		.overlay(
			RoundedRectangle(cornerRadius: 3)
				.strokeBorder(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
		)
		.accessibilityLabel(alt.isEmpty ? "Image failed to load" : "Image failed to load: \(alt)")
	}
}
