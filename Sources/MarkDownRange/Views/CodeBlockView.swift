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
	var showLineNumbers: Bool = true
	@State private var isContentHovering = false
	@State private var isButtonHovering = false

	private var trimmedCode: String { code.trimmingCharacters(in: .newlines) }

	// The heavy code body (line numbers + syntax-highlighted text) lives in its
	// own view that does not observe hover state. Without this split, every cursor
	// enter/exit during scroll rebuilt the line-number ForEach and triggered the
	// implicit animation, redrawing the whole block for 150ms. Now only the copy
	// button reacts to hover.
	var body: some View {
		ZStack(alignment: .topTrailing) {
			CodeBlockContent(code: trimmedCode, theme: theme, showLineNumbers: showLineNumbers)

			CodeBlockCopyButton(
				code: trimmedCode,
				language: language,
				theme: theme,
				isContentHovering: isContentHovering,
				isButtonHovering: $isButtonHovering
			)
		}
		.background(theme.codeBackground, in: RoundedRectangle(cornerRadius: 8))
		.contentShape(Rectangle())
		.onHover { isContentHovering = $0 }
	}
}

private struct CodeBlockContent: View {
	let code: String
	let theme: MarkdownTheme
	let showLineNumbers: Bool
	@State private var highlightedText: Text?

	private var lineCount: Int { code.components(separatedBy: .newlines).count }

	var body: some View {
		PassThroughHorizontalScroll {
			HStack(alignment: .top, spacing: 0) {
				if showLineNumbers {
					VStack(alignment: .trailing, spacing: 0) {
						ForEach(1...max(1, lineCount), id: \.self) { num in
							Text("\(num)")
								.font(.system(size: 13, design: .monospaced))
								.foregroundStyle(theme.secondaryColor.opacity(0.5))
								.frame(height: 18.5)
						}
					}
					.padding(.leading, 12)
					.padding(.trailing, 8)
					.padding(.vertical, 12)

					Divider().padding(.vertical, 4)
				}

				(highlightedText ?? Text(code))
					.font(.system(size: 13, design: .monospaced))
					.textSelection(.enabled)
					.padding(12)
					.padding(.trailing, 24)
			}
		}
		.task(id: code) {
			let source = code
			let text = await Task.detached { Tokenizer.highlightedText(source) }.value
			highlightedText = text
		}
	}
}

private struct CodeBlockCopyButton: View {
	let code: String
	let language: String?
	let theme: MarkdownTheme
	let isContentHovering: Bool
	@Binding var isButtonHovering: Bool
	@State private var copied = false

	private var isHovering: Bool { isContentHovering || isButtonHovering }

	var body: some View {
		MarkdownAccessoryButton(
			systemImage: copied ? "checkmark" : "doc.on.doc",
			tint: copied ? .green : nil,
			theme: theme,
			label: copied ? "Copied" : "Copy \(language ?? "code")"
		) { copyToClipboard() }
		.padding(12)
		.opacity((isHovering || copied) ? 1 : 0)
		.allowsHitTesting(isHovering || copied)
		.onHover { isButtonHovering = $0 }
		.animation(.easeInOut(duration: 0.15), value: isHovering)
		.animation(.easeInOut(duration: 0.15), value: copied)
	}

	private func copyToClipboard() {
		#if os(macOS)
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(code, forType: .string)
		#else
		UIPasteboard.general.string = code
		#endif
		copied = true
		Task {
			try? await Task.sleep(for: .seconds(2))
			copied = false
		}
	}
}
