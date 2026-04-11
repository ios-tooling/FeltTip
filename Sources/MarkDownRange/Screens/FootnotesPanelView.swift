//
//  FootnotesPanelView.swift
//  MarkdownRendering
//

import SwiftUI

public struct FootnotesPanelView: View {
	let footnotes: [MarkdownFootnote]
	@Binding var isExpanded: Bool
	@Binding var highlightedID: String?
	let theme: MarkdownTheme
	let fontSize: CGFloat
	@State private var flashingID: String?

	public init(
		footnotes: [MarkdownFootnote],
		isExpanded: Binding<Bool>,
		highlightedID: Binding<String?>,
		theme: MarkdownTheme,
		fontSize: CGFloat
	) {
		self.footnotes = footnotes
		self._isExpanded = isExpanded
		self._highlightedID = highlightedID
		self.theme = theme
		self.fontSize = fontSize
	}

	private var noteSize: CGFloat { max(11, fontSize - 2) }

	public var body: some View {
		VStack(spacing: 0) {
			Divider()

			Button {
				withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
			} label: {
				HStack(spacing: 6) {
					Image(systemName: "note.text")
						.font(.caption)
					Text(footnotes.count == 1 ? "1 Footnote" : "\(footnotes.count) Footnotes")
						.font(.caption.weight(.medium))
					Spacer()
					Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
						.font(.caption2)
				}
				.padding(.horizontal)
				.padding(.vertical, 6)
				.foregroundStyle(.secondary)
			}
			.buttonStyle(.plain)

			if isExpanded {
				Divider()
				ScrollViewReader { proxy in
					ScrollView {
						VStack(alignment: .leading, spacing: 12) {
							ForEach(footnotes) { footnote in
								HStack(alignment: .top, spacing: 10) {
									Text("\(footnote.displayIndex).")
										.font(.system(size: noteSize, design: .monospaced))
										.foregroundStyle(.secondary)
										.frame(minWidth: 24, alignment: .trailing)
									MarkdownContentView(
										markdown: footnote.content,
										theme: theme,
										fontSize: noteSize
									)
									.frame(maxWidth: .infinity, alignment: .leading)
								}
								.padding(6)
								.background(
									RoundedRectangle(cornerRadius: 6)
										.fill(.tint.opacity(flashingID == footnote.id ? 0.2 : 0))
								)
								.id(footnote.id)
							}
						}
						.padding(.horizontal)
						.padding(.vertical, 8)
					}
					.frame(maxHeight: 220)
					.background(theme.backgroundColor)
					.onAppear {
						guard let id = highlightedID else { return }
						Task { @MainActor in
							try? await Task.sleep(for: .milliseconds(200))
							scroll(to: id, proxy: proxy)
						}
					}
					.onChange(of: highlightedID) { _, id in
						guard let id else { return }
						scroll(to: id, proxy: proxy)
					}
				}
			}
		}
		.background(theme.backgroundColor)
		.onChange(of: highlightedID) { _, id in
			if id != nil, !isExpanded {
				withAnimation(.easeInOut(duration: 0.2)) { isExpanded = true }
			}
		}
	}

	private func scroll(to id: String, proxy: ScrollViewProxy) {
		withAnimation { proxy.scrollTo(id, anchor: .center) }
		Task { @MainActor in
			withAnimation(.easeIn(duration: 0.15)) { flashingID = id }
			try? await Task.sleep(for: .milliseconds(800))
			withAnimation(.easeOut(duration: 0.4)) { flashingID = nil }
			highlightedID = nil
		}
	}
}
