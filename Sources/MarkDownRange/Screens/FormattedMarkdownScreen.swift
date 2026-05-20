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
	var onVisibleSectionChanged: ((String) -> Void)?
	/// Fires whenever the async render task finishes and the section list
	/// becomes available (or refreshes due to a key change). Lets snapshot
	/// tooling avoid capturing while the canvas is still blank.
	var onRenderReady: (() -> Void)?
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
		onVisibleSectionChanged: ((String) -> Void)? = nil,
		onRenderReady: (() -> Void)? = nil
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
		self.onVisibleSectionChanged = onVisibleSectionChanged
		self.onRenderReady = onRenderReady
	}

	private var renderKey: FormattedMarkdownRenderModel.Key {
		FormattedMarkdownRenderModel.Key(text: text, theme: theme, fontSize: fontSize)
	}

	public var body: some View {
		VStack(spacing: 0) {
			if renderModel == nil {
				// First parse happens on a detached task. Show a spinner so
				// the window doesn't appear blank while it runs.
				ProgressView()
					.controlSize(.large)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
					.background(theme.backgroundColor)
			}
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
									onLinkHover: { url in
									if linkDisplay.displayedURL != url { linkDisplay.displayedURL = url }
								}
								)
								.frame(maxWidth: .infinity, alignment: .leading)
								.padding(.horizontal)
								.background(
									RoundedRectangle(cornerRadius: 4)
										.fill(.tint.opacity(sectionBackgroundOpacity(for: section.id)))
										.padding(.horizontal, 4)
								)
								.onContinuousHover { phase in
									guard focusModeEnabled else { return }
									switch phase {
									case .active: focusedSectionID = section.id
									case .ended:
										if focusedSectionID == section.id { focusedSectionID = nil }
									}
								}
								.background(
									GeometryReader { geo in
										Color.clear.preference(
											key: VisibleSectionKey.self,
											value: geo.frame(in: .named("formattedScroll")).minY <= VisibleSectionKey.indicatorLine ? section.id : nil
										)
									}
								)
								.id(section.id)
							}
						}
						.padding(.vertical)
						#if os(macOS)
						ScrollFractionSyncer(
							incoming: syncScrollFraction,
							onChanged: onScrollFractionChanged ?? { _ in }
						)
						#endif
					}
					.coordinateSpace(name: "formattedScroll")
					.font(.system(size: fontSize))
					.background(theme.backgroundColor)
					.onPreferenceChange(VisibleSectionKey.self) { id in
						if let id { onVisibleSectionChanged?(id) }
					}
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
				onRenderReady?()
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
			let fullyProcessed = MarkdownPreprocessor.common(after: withCitations)
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

private struct VisibleSectionKey: PreferenceKey {
	/// Indicator line in the scroll view's coordinate space. The "current"
	/// section is the bottom-most one whose top has reached or moved above
	/// this line — i.e., the section whose heading is currently sitting at
	/// (or just above) the top of the visible area.
	static let indicatorLine: CGFloat = 80

	static let defaultValue: String? = nil

	// Each section emits its id only when above the indicator, so the reduced
	// value changes only when crossing a section boundary — not every scroll
	// tick. This keeps `onPreferenceChange` quiet during smooth scrolling.
	static func reduce(value: inout String?, nextValue: () -> String?) {
		if let next = nextValue() { value = next }
	}
}
