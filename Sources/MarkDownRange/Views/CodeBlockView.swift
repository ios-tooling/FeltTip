//
//  CodeBlockView.swift
//  MarkDownRange
//

import SwiftUI
import MarkdownSyntaxHighlighting

struct CodeBlockView: View {
	let code: String
	let language: String?
	let theme: MarkdownTheme
	@State private var copied = false

	private var trimmedCode: String { code.trimmingCharacters(in: .newlines) }

	var body: some View {
		ZStack(alignment: .topTrailing) {
			ScrollView(.horizontal, showsIndicators: false) {
				Tokenizer.highlightedText(trimmedCode)
					.font(.system(size: 13, design: .monospaced))
					.textSelection(.enabled)
					.padding(16)
					.padding(.trailing, 32)
			}

			Button {
				copyToClipboard()
			} label: {
				Image(systemName: copied ? "checkmark" : "doc.on.doc")
					.font(.system(size: 12))
					.foregroundStyle(copied ? .green : theme.secondaryColor)
					.padding(6)
					.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
			}
			.buttonStyle(.plain)
			.padding(8)
		}
		.background(theme.codeBackground, in: RoundedRectangle(cornerRadius: 8))
	}

	private func copyToClipboard() {
		#if os(macOS)
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(trimmedCode, forType: .string)
		#else
		UIPasteboard.general.string = trimmedCode
		#endif
		copied = true
		Task {
			try? await Task.sleep(for: .seconds(2))
			copied = false
		}
	}
}
