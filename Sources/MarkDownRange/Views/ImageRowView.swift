//
//  ImageRowView.swift
//  MarkDownRange
//

import SwiftUI

struct ImageRowView: View {
	let images: [ImageRowItem]
	let theme: MarkdownTheme
	let baseURL: URL?
	var onLinkHover: ((String?) -> Void)? = nil

	var body: some View {
		HStack(spacing: 8) {
			ForEach(Array(images.enumerated()), id: \.offset) { _, item in
				imageCell(item)
			}
		}
	}

	@ViewBuilder private func imageCell(_ item: ImageRowItem) -> some View {
		if let url = resolvedURL(for: item.source) {
			let image = ScaleDownImage(url: url, alt: item.alt, htmlWidth: item.width, htmlHeight: item.height)
			if let link = item.link {
				PopoutableImageView(
					url: url,
					alt: item.alt,
					theme: theme,
					htmlWidth: item.width,
					htmlHeight: item.height
				) {
					SwiftUI.Link(destination: link) { image }
						.onHover { hovering in
							onLinkHover?(hovering ? link.absoluteString : nil)
						}
				}
			} else {
				PopoutableImageView(
					url: url,
					alt: item.alt,
					theme: theme,
					htmlWidth: item.width,
					htmlHeight: item.height
				) {
					image
				}
			}
		}
	}

	private func resolvedURL(for source: String) -> URL? {
		if let url = URL(string: source), url.scheme != nil { return url }
		if let baseURL { return URL(string: source, relativeTo: baseURL) }
		if let baseURL { return baseURL.appendingPathComponent(source) }
		return URL(string: source)
	}
}
