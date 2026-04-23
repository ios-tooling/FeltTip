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
	@State private var showBibliography = false
	@State private var highlightedFootnoteID: String?
	@State private var renderModel: FormattedMarkdownRenderModel?
	@State private var renderTask: Task<Void, Never>?
	@State private var focusedSectionID: String?
	var syncSectionID: String?
	var syncScrollFraction: Double?
	var focusModeEnabled: Bool = false
	var onScrollFractionChanged: ((Double) -> Void)?
	var highlightedSectionID: String?
	var onSectionTapped: ((String) -> Void)?
	@Environment(LinkDisplayState.self) var linkDisplay

	public init(
		text: String,
		selectedHeadingID: Binding<String?>,
		baseURL: URL? = nil,
		theme: MarkdownTheme,
		fontSize: CGFloat,
		syncSectionID: String? = nil,
		syncScrollFraction: Double? = nil,
		focusModeEnabled: Bool = false,
		onScrollFractionChanged: ((Double) -> Void)? = nil,
		highlightedSectionID: String? = nil,
		onSectionTapped: ((String) -> Void)? = nil
	) {
		self.text = text
		self._selectedHeadingID = selectedHeadingID
		self.baseURL = baseURL
		self.theme = theme
		self.fontSize = fontSize
		self.syncSectionID = syncSectionID
		self.syncScrollFraction = syncScrollFraction
		self.focusModeEnabled = focusModeEnabled
		self.onScrollFractionChanged = onScrollFractionChanged
		self.highlightedSectionID = highlightedSectionID
		self.onSectionTapped = onSectionTapped
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
										.fill(.tint.opacity(sectionBackgroundOpacity(for: section.id)))
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
								.onTapGesture {
									onSectionTapped?(section.id)
								}
								.id(section.id)
							}
						}
						.padding(.vertical)
						#if os(macOS)
						if let fraction = syncScrollFraction {
							ScrollFractionReceiver(fraction: fraction)
						}
						ScrollFractionReporter(onChanged: onScrollFractionChanged ?? { _ in })
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

				if !renderModel.citations.isEmpty {
					BibliographyPanelView(
						citations: renderModel.citations,
						isExpanded: $showBibliography,
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
			if url.scheme == "citation", let id = url.host, !id.isEmpty {
				showBibliography = true
				linkDisplay.show(url: "Citation: \(id)")
				return .handled
			}
			if url.scheme == "wikilink", let page = url.host?.removingPercentEncoding, let base = baseURL {
				let fileURL = base.appendingPathComponent(page).appendingPathExtension("md")
				if FileManager.default.fileExists(atPath: fileURL.path) {
					#if os(macOS)
					NSWorkspace.shared.open(fileURL)
					#endif
					return .handled
				}
				linkDisplay.show(url: "\(page).md (not found)")
				return .handled
			}
			linkDisplay.show(url: url.absoluteString)
			return .systemAction
		})
	}

	private func sectionBackgroundOpacity(for sectionID: String) -> Double {
		if flashingID == sectionID { return 0.15 }
		if highlightedSectionID == sectionID { return 0.08 }
		return 0
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
		private let textHash: Int

		init(text: String, theme: MarkdownTheme, fontSize: CGFloat) {
			self.text = text
			self.theme = theme
			self.fontSize = fontSize
			self.textHash = text.hashValue
		}

		static func == (lhs: Key, rhs: Key) -> Bool {
			lhs.textHash == rhs.textHash && lhs.fontSize == rhs.fontSize && lhs.theme == rhs.theme && lhs.text == rhs.text
		}
	}

	let key: Key
	let footnotes: [MarkdownFootnote]
	let citations: [Citation]
	let sections: [RenderedMarkdownSection]

	init(key: Key) async {
		self.key = key
		let text = key.text
		let theme = key.theme
		let fontSize = key.fontSize
		let (footnotes, citations, sections) = await Task.detached {
			let footnotes = MarkdownFootnote.parse(from: text)
			let citations = Citation.parse(from: text)
			let withFootnotes = MarkdownFootnote.renderableContent(from: text, footnotes: footnotes)
			let withCitations = Citation.renderableContent(from: withFootnotes, citations: citations)
			let withSuperSub = SuperSubProcessor.process(withCitations)
			let fullyProcessed = WikilinkProcessor.process(DefinitionListProcessor.process(HighlightSyntax.process(EmojiShortcodes.process(withSuperSub))))
			var checkboxOffset = 0
			let sections = MarkdownSection.parse(from: fullyProcessed).map { section in
				let blocks = MarkdownBlockParser.parse(section.content, theme: theme, fontSize: fontSize, checkboxOffset: checkboxOffset, preprocessed: true)
				checkboxOffset += Self.checkboxCount(in: blocks)
				return RenderedMarkdownSection(id: section.id, blocks: blocks)
			}
			return (footnotes, citations, sections)
		}.value
		self.footnotes = footnotes
		self.citations = citations
		self.sections = sections
	}

	private static func checkboxCount(in blocks: [MarkdownBlock]) -> Int {
		blocks.reduce(0) { total, block in
			switch block {
			case .orderedList(let items, _, _), .unorderedList(let items, _):
				let itemCount = items.filter { $0.checkbox != nil }.count
				let nested = items.flatMap(\.blocks)
				return total + itemCount + checkboxCount(in: nested)
			case .blockquote(let children, _), .details(_, let children, _), .alert(_, let children, _):
				return total + checkboxCount(in: children)
			default: return total
			}
		}
	}
}

private struct RenderedMarkdownSection: Identifiable {
	let id: String
	let blocks: [MarkdownBlock]
}
