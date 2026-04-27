//
//  ParagraphBlockView.swift
//  MarkdownRendering
//

import SwiftUI

struct ParagraphBlockView: View {
	let content: AttributedString
	let links: [LinkInfo]
	let onLinkHover: ((String?) -> Void)?
	@Environment(\.markdownTextSelectionEnabled) private var selectionEnabled

	@ViewBuilder private var textView: some View {
		if selectionEnabled {
			Text(content).textSelection(.enabled)
		} else {
			Text(content).textSelection(.disabled)
		}
	}

	// Per-paragraph onContinuousHover was previously used to surface the hovered
	// link's URL in the status bar. In documents with many link-bearing paragraphs
	// (e.g. the CommonMark spec) the per-paragraph tracking area was the dominant
	// scroll-time cost: AppKit revalidates every tracking area on each scroll
	// frame, and SwiftUI's StyledTextResponder enumerates the AttributedString's
	// link attributes per hit-test. Dropping the modifier eliminates those costs.
	// The link URL is still visible in the system tooltip on hover.
	var body: some View {
		textView
	}
}
