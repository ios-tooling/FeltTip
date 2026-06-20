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
		// The copy button is an overlay, not a ZStack sibling: an overlay floats
		// on top without contributing to the block's measured size. As a sibling
		// its height padded the block out, leaving a phantom empty line below
		// short snippets.
		CodeBlockContent(code: trimmedCode, theme: theme, showLineNumbers: showLineNumbers)
			.overlay(alignment: .topTrailing) {
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
			.padding(.vertical, 4)
	}
}

private struct CodeBlockContent: View {
	let code: String
	let theme: MarkdownTheme
	let showLineNumbers: Bool
	@State private var highlightedLines: [Text]?

	private var rawLines: [String] { code.components(separatedBy: .newlines) }
	private var lineCount: Int { rawLines.count }

	// Line numbers are noise on a one- or two-line snippet, so they're reserved
	// for longer blocks.
	private var showsLineNumbers: Bool { showLineNumbers && lineCount > 2 }

	var body: some View {
		// Each source line is its own row so it can wrap to the content width
		// like body text. Its line number stays pinned to the line's first
		// visual row (.topLeading) — the wrapped remainder carries no number,
		// so numbering tracks real source lines rather than visual ones.
		let lines = highlightedLines ?? rawLines.map { $0.isEmpty ? Text(" ") : Text($0) }
		VStack(alignment: .leading, spacing: 0) {
			ForEach(Array(lines.enumerated()), id: \.offset) { index, lineText in
				HStack(alignment: .top, spacing: 8) {
					if showsLineNumbers {
						// A hidden copy of the widest number sizes the gutter so
						// every number right-aligns in the same column without a
						// hard-coded width.
						ZStack(alignment: .trailing) {
							Text("\(lineCount)").hidden()
							Text("\(index + 1)")
								.foregroundStyle(theme.secondaryColor.opacity(0.5))
						}
					}
					// maxWidth caps the code at the row's remaining width so long
					// lines wrap to the next visual row instead of overflowing.
					lineText
						.textSelection(.enabled)
						.frame(maxWidth: .infinity, alignment: .leading)
				}
			}
		}
		.font(.system(size: 13, design: .monospaced))
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(12)
		.padding(.trailing, 24)
		.task(id: code) {
			let source = code
			highlightedLines = await Task.detached { Tokenizer.highlightedLines(source) }.value
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
