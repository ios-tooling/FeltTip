//
//  ImageRowView.swift
//  MarkDownRange
//

import SwiftUI

struct ImageRowView: View {
	let images: [ImageRowItem]
	var onLinkHover: ((String?) -> Void)? = nil

	var body: some View {
		HStack(spacing: 8) {
			ForEach(Array(images.enumerated()), id: \.offset) { _, item in
				imageCell(item)
			}
		}
	}

	@ViewBuilder private func imageCell(_ item: ImageRowItem) -> some View {
		if let url = URL(string: item.source) {
			let image = ScaleDownImage(url: url, alt: item.alt, htmlWidth: item.width, htmlHeight: item.height)
			if let link = item.link {
				SwiftUI.Link(destination: link) { image }
					.onHover { hovering in
						onLinkHover?(hovering ? link.absoluteString : nil)
					}
			} else {
				image
			}
		}
	}
}
