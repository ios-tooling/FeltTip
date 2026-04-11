//
//  HTMLBlockView.swift
//  MarkdownRendering
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct HTMLBlockView: View {
	let html: String
	let theme: MarkdownTheme
	let fontSize: CGFloat

	private var attributedContent: AttributedString {
		let styledHTML = "<div style=\"font-family: -apple-system; font-size: \(Int(fontSize))px;\">\(html)</div>"
		guard let data = styledHTML.data(using: .utf8),
				let nsAttr = try? NSAttributedString(
					data: data,
					options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
					documentAttributes: nil
				) else {
			return AttributedString(html)
		}
		return (try? AttributedString(nsAttr, including: \.swiftUI)) ?? AttributedString(html)
	}

	var body: some View {
		Text(attributedContent)
			.textSelection(.enabled)
	}
}
