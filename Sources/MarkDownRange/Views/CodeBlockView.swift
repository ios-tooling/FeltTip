//
//  CodeBlockView.swift
//  MarkdownRendering
//

import SwiftUI
import MarkdownSyntaxHighlighting

struct CodeBlockView: View {
	let code: String
	let language: String?
	let theme: MarkdownTheme

	var body: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			Tokenizer.highlightedText(code.trimmingCharacters(in: .newlines))
				.font(.system(size: 13, design: .monospaced))
				.textSelection(.enabled)
				.padding(16)
		}
		.background(theme.codeBackground, in: RoundedRectangle(cornerRadius: 8))
	}
}
