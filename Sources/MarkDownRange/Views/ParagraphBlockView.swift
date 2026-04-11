//
//  ParagraphBlockView.swift
//  MarkdownRendering
//

import SwiftUI

struct ParagraphBlockView: View {
	let content: AttributedString
	let links: [LinkInfo]
	let onLinkHover: ((String?) -> Void)?

	var body: some View {
		Text(content)
			.textSelection(.enabled)
			.onContinuousHover { phase in
				guard let onLinkHover, !links.isEmpty else { return }
				switch phase {
				case .active(let point):
					if links.count == 1 {
						onLinkHover(links[0].url)
					} else {
						let totalChars = content.characters.count
						guard totalChars > 0 else { return }
						// Estimate which link by horizontal position
						let fraction = max(0, min(1, point.x / 600))
						let charEstimate = Int(fraction * Double(totalChars))
						let link = links.last { $0.characterOffset <= charEstimate } ?? links[0]
						onLinkHover(link.url)
					}
				case .ended:
					onLinkHover(nil)
				}
			}
	}
}
