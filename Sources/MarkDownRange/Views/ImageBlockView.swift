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

	private var resolvedURL: URL? {
		if let url = URL(string: source), url.scheme != nil { return url }
		if let base = baseURL { return URL(string: source, relativeTo: base) }
		// Try as a file path relative to baseURL
		if let base = baseURL { return base.appendingPathComponent(source) }
		return URL(string: source)
	}

	var body: some View {
		if let url = resolvedURL {
			CachedURLImage(url: url, contentMode: .fit, placeholder: Image(systemName: "photo"))
				.frame(maxWidth: .infinity, alignment: .center)
				.accessibilityLabel(alt.isEmpty ? "Image" : alt)
		} else {
			Label(alt.isEmpty ? source : alt, systemImage: "photo")
				.foregroundStyle(.secondary)
				.padding(8)
				.frame(maxWidth: .infinity, alignment: .center)
				.background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
		}
	}
}
