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
	let size: CGSize?

	var body: some View {
		HStack(alignment: .top, spacing: 6) {
			Image(systemName: "photo.badge.exclamationmark")
				.foregroundStyle(.secondary)
			if !alt.isEmpty {
				Text(alt)
					.foregroundStyle(.primary)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
		.padding(8)
		.frame(width: size?.width, height: size?.height, alignment: .topLeading)
		.background(.quaternary.opacity(0.5))
		.overlay(
			RoundedRectangle(cornerRadius: 4)
				.strokeBorder(.secondary.opacity(0.4))
		)
		.accessibilityLabel(alt.isEmpty ? "Image failed to load" : "Image failed to load: \(alt)")
	}
}
