//
//  ImageRowView.swift
//  MarkDownRange
//

import SwiftUI
import Convey

struct ImageRowView: View {
	let images: [(source: String, alt: String, link: URL?, width: CGFloat?, height: CGFloat?)]

	var body: some View {
		HStack(spacing: 8) {
			ForEach(Array(images.enumerated()), id: \.offset) { _, item in
				imageCell(item)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	@ViewBuilder private func imageCell(_ item: (source: String, alt: String, link: URL?, width: CGFloat?, height: CGFloat?)) -> some View {
		if let url = URL(string: item.source) {
			let image = ScaleDownImage(url: url, alt: item.alt, htmlWidth: item.width, htmlHeight: item.height)
			if let link = item.link {
				SwiftUI.Link(destination: link) { image }
			} else {
				image
			}
		}
	}
}
