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
	@State private var copied = false
	@State private var highlightedText: Text?
	@State private var isContentHovering = false
	@State private var isButtonHovering = false

	private var isHovering: Bool { isContentHovering || isButtonHovering }

	private var trimmedCode: String { code.trimmingCharacters(in: .newlines) }
	private var lineCount: Int { trimmedCode.components(separatedBy: .newlines).count }

	var body: some View {
		ZStack(alignment: .topTrailing) {
			ScrollView(.horizontal, showsIndicators: false) {
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

					(highlightedText ?? Text(trimmedCode))
						.font(.system(size: 13, design: .monospaced))
						.textSelection(.enabled)
						.padding(12)
						.padding(.trailing, 24)
				}
			}

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
		}
		.background(theme.codeBackground, in: RoundedRectangle(cornerRadius: 8))
		.contentShape(Rectangle())
		.onHover { isContentHovering = $0 }
		.animation(.easeInOut(duration: 0.15), value: isHovering)
		.animation(.easeInOut(duration: 0.15), value: copied)
		.task(id: trimmedCode) {
			let code = trimmedCode
			let text = await Task.detached { Tokenizer.highlightedText(code) }.value
			highlightedText = text
		}
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
