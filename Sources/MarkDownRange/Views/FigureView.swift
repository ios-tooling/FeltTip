//
//  FigureView.swift
//  MarkDownRange
//
//  Renders an image with a caption beneath it, mirroring how Pandoc and
//  kramdown promote a standalone `![alt](url "caption")` to a <figure>
//  with <figcaption>. The block-builder only emits this when the markdown
//  title attribute is set, so the caption is always an explicit author
//  opt-in — existing alt-text-as-accessibility documents are unaffected.
//

import SwiftUI

struct FigureView: View {
	let image: ImageRowItem
	let caption: String
	let theme: MarkdownTheme
	let baseURL: URL?

	var body: some View {
		VStack(alignment: .center, spacing: 6) {
			ImageBlockView(
				source: image.source,
				alt: image.alt,
				theme: theme,
				baseURL: baseURL,
				htmlWidth: image.width,
				htmlHeight: image.height
			)
			Text(caption)
				.font(.caption)
				.foregroundStyle(theme.secondaryColor)
				.multilineTextAlignment(.center)
		}
		.frame(maxWidth: .infinity)
	}
}
