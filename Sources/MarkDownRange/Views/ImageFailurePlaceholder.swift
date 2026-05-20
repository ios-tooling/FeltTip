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
		VStack(spacing: 8) {
			Image(systemName: "photo.badge.exclamationmark")
				.font(.system(size: 28))
				.foregroundStyle(Color.secondary)
			if !alt.isEmpty {
				Text(alt)
					.font(.callout)
					.foregroundStyle(Color.primary)
					.multilineTextAlignment(.center)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
		.padding(16)
		.frame(width: size?.width, height: size?.height)
		.background(Color.gray.opacity(0.15))
		.overlay(
			RoundedRectangle(cornerRadius: 4)
				.strokeBorder(Color.secondary.opacity(0.4))
		)
		.accessibilityLabel(alt.isEmpty ? "Image failed to load" : "Image failed to load: \(alt)")
	}
}
