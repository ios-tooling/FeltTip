//
//  ImageBlockView.swift
//  MarkdownRendering
//

import SwiftUI
import Convey

struct ImageBlockView: View {
	let source: String
	let alt: String
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
			ScaleDownImage(url: url, alt: alt, htmlWidth: htmlWidth, htmlHeight: htmlHeight)
				.frame(maxWidth: .infinity, alignment: .leading)
		} else {
			Label(alt.isEmpty ? source : alt, systemImage: "photo")
				.foregroundStyle(.secondary)
				.padding(8)
				.frame(maxWidth: .infinity, alignment: .leading)
				.background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
		}
	}
}
