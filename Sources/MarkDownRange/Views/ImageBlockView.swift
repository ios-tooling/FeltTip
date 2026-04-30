//
//  ImageBlockView.swift
//  MarkdownRendering
//

import SwiftUI
import Convey

struct ImageBlockView: View {
	let source: String
	let alt: String
	let theme: MarkdownTheme
	let baseURL: URL?
	var htmlWidth: CGFloat?
	var htmlHeight: CGFloat?

	private var resolvedURL: URL? {
		if let url = URL(string: source), url.scheme != nil { return url }
		if let base = baseURL { return URL(string: source, relativeTo: base) }
		if let base = baseURL { return base.appendingPathComponent(source) }
		return URL(string: source)
	}

	var body: some View {
		if let url = resolvedURL {
			PopoutableImageView(
				url: url,
				alt: alt,
				theme: theme,
				htmlWidth: htmlWidth,
				htmlHeight: htmlHeight
			) {
				ScaleDownImage(url: url, alt: alt, htmlWidth: htmlWidth, htmlHeight: htmlHeight)
			}
		} else {
			Label(alt.isEmpty ? source : alt, systemImage: "photo")
				.foregroundStyle(.secondary)
				.padding(8)
				.background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
		}
	}
}
