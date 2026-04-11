//
//  FormattedMarkdownScreen.swift
//  MarkdownRendering
//

import SwiftUI

public struct FormattedMarkdownScreen: View {
	let text: String
	@Binding var selectedHeadingID: String?
	var baseURL: URL?
	let theme: MarkdownTheme
	let fontSize: CGFloat
	@State private var flashingID: String?
	@State private var showFootnotes = false
	@State private var highlightedFootnoteID: String?
	@State private var renderModel: FormattedMarkdownRenderModel?
	@State private var renderTask: Task<Void, Never>?
	@State private var focusedSectionID: String?
	var syncSectionID: String?
	var syncScrollFraction: Double?
	var focusModeEnabled: Bool = false
	@Environment(LinkDisplayState.self) var linkDisplay

	public init(
		text: String,
		selectedHeadingID: Binding<String?>,
		baseURL: URL? = nil,
		theme: MarkdownTheme,
		fontSize: CGFloat,
		syncSectionID: String? = nil,
		syncScrollFraction: Double? = nil,
		focusModeEnabled: Bool = false
	) {
		self.text = text
		self._selectedHeadingID = selectedHeadingID
		self.baseURL = baseURL
		self.theme = theme
		self.fontSize = fontSize
		self.syncSectionID = syncSectionID
		self.syncScrollFraction = syncScrollFraction
		self.focusModeEnabled = focusModeEnabled
	}

	private var renderKey: FormattedMarkdownRenderModel.Key {
		FormattedMarkdownRenderModel.Key(text: text, theme: theme, fontSize: fontSize)
	}

	public var body: some View {
		VStack(spacing: 0) {
			if let renderModel {
				ScrollViewReader { proxy in
					ScrollView {
						LazyVStack(alignment: .leading, spacing: 0) {
							ForEach(renderModel.sections) { section in
								MarkdownContentView(
									blocks: section.blocks,
									theme: theme,
									fontSize: fontSize,
									baseURL: baseURL,
									onLinkHover: { linkDisplay.displayedURL = $0 }
								)
								.frame(maxWidth: .infinity, alignment: .leading)
								.padding(.horizontal)
								.background(
									RoundedRectangle(cornerRadius: 4)
										.fill(.tint.opacity(flashingID == section.id ? 0.15 : 0))
										.padding(.horizontal, 4)
								)
								.opacity(focusModeOpacity(for: section.id))
								.onContinuousHover { phase in
									guard focusModeEnabled else { return }
									switch phase {
									case .active: focusedSectionID = section.id
									case .ended:
										if focusedSectionID == section.id { focusedSectionID = nil }
									}
								}
								.id(section.id)
							}
						}
						.padding(.vertical)
						#if os(macOS)
						if let fraction = syncScrollFraction {
							ScrollFractionReceiver(fraction: fraction)
						}
						#endif
					}
					.font(.system(size: fontSize))
					.background(theme.backgroundColor)
					.onChange(of: selectedHeadingID) { _, raw in
						guard let raw else { return }
						let id = raw.components(separatedBy: "\t").first ?? raw
						withAnimation { proxy.scrollTo(id, anchor: .top) }
						Task { @MainActor in
							withAnimation(.easeIn(duration: 0.15)) { flashingID = id }
							try? await Task.sleep(for: .milliseconds(600))
							withAnimation(.easeOut(duration: 0.4)) { flashingID = nil }
							selectedHeadingID = nil
						}
					}
				}

				if !renderModel.footnotes.isEmpty {
					FootnotesPanelView(
						footnotes: renderModel.footnotes,
						isExpanded: $showFootnotes,
						highlightedID: $highlightedFootnoteID,
						theme: theme,
						fontSize: fontSize
					)
				}
			}
		}
		.onChange(of: renderKey, initial: true) { _, key in
			renderTask?.cancel()
			renderTask = Task {
				let model = await FormattedMarkdownRenderModel(key: key)
				guard !Task.isCancelled else { return }
				renderModel = model
			}
		}
		.environment(\.openURL, OpenURLAction { url in
			if url.scheme == "footnote", let id = url.host, !id.isEmpty {
				highlightedFootnoteID = id
				linkDisplay.show(url: "Footnote \(id)")
				return .handled
			}
			linkDisplay.show(url: url.absoluteString)
			return .systemAction
		})
	}

	private func focusModeOpacity(for sectionID: String) -> Double {
		guard focusModeEnabled, focusedSectionID != nil else { return 1.0 }
		return focusedSectionID == sectionID ? 1.0 : 0.25
	}
}

private struct FormattedMarkdownRenderModel {
	struct Key: Equatable {
		let text: String
		let theme: MarkdownTheme
		let fontSize: CGFloat
	}

	let key: Key
	let footnotes: [MarkdownFootnote]
	let sections: [RenderedMarkdownSection]

	init(key: Key) async {
		self.key = key
		let text = key.text
		let theme = key.theme
		let fontSize = key.fontSize
		let (footnotes, sections) = await Task.detached {
			let footnotes = MarkdownFootnote.parse(from: text)
			let sections = MarkdownSection.parse(from: text).map { section in
				let content = MarkdownFootnote.renderableContent(from: section.content, footnotes: footnotes)
				let rendered = SuperSubProcessor.process(content)
				let blocks = MarkdownBlockParser.parse(rendered, theme: theme, fontSize: fontSize)
				return RenderedMarkdownSection(id: section.id, blocks: blocks)
			}
			return (footnotes, sections)
		}.value
		self.footnotes = footnotes
		self.sections = sections
	}
}

private struct RenderedMarkdownSection: Identifiable {
	let id: String
	let blocks: [MarkdownBlock]
}
