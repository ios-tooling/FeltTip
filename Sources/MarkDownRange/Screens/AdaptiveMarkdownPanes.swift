//
//  AdaptiveMarkdownPanes.swift
//  MarkDownRange
//
//  iOS layout for the source/rendered pair. macOS puts them side by side in an
//  HSplitView unconditionally; a phone has no room for that.
//
//  Regular width (iPad landscape, Stage Manager) keeps both panes visible.
//  Compact width shows one at a time behind a segmented switch, carrying the
//  scroll position across so switching doesn't lose the reader's place.
//  Stacking the two vertically on a phone was the alternative and is worse:
//  with the software keyboard up, each pane gets a few dozen points.
//
//  Since styled editing works on iOS, the rendered pane is the primary editor
//  and the source pane is the escape hatch — so compact width opens rendered.
//

#if os(iOS)
import SwiftUI

struct AdaptiveMarkdownPanes: View {
	@Environment(\.horizontalSizeClass) private var sizeClass
	@Binding var text: String
	@Binding var selectedHeadingID: String?
	let context: MarkdownPaneContext
	var initialScrollFraction: Double?
	var onScrollFractionChanged: ((Double) -> Void)?

	@State private var pane: Pane = .rendered
	@State private var scrollFraction: Double = 0
	@State private var didSeedScroll = false

	enum Pane: String, CaseIterable, Identifiable {
		case rendered, source
		var id: Self { self }
		var label: String { self == .rendered ? "Rendered" : "Source" }
	}

	var body: some View {
		Group {
			if sizeClass == .compact {
				CompactMarkdownPanes(
					pane: $pane, text: $text, selectedHeadingID: $selectedHeadingID,
					scrollFraction: $scrollFraction, context: context,
					onScrollFractionChanged: onScrollFractionChanged)
			} else {
				RegularMarkdownPanes(
					text: $text, selectedHeadingID: $selectedHeadingID,
					scrollFraction: $scrollFraction, context: context,
					onScrollFractionChanged: onScrollFractionChanged)
			}
		}
		.onAppear {
			guard !didSeedScroll, let initialScrollFraction else { return }
			didSeedScroll = true
			scrollFraction = initialScrollFraction
		}
	}
}

private struct CompactMarkdownPanes: View {
	@Binding var pane: AdaptiveMarkdownPanes.Pane
	@Binding var text: String
	@Binding var selectedHeadingID: String?
	@Binding var scrollFraction: Double
	let context: MarkdownPaneContext
	var onScrollFractionChanged: ((Double) -> Void)?

	var body: some View {
		VStack(spacing: 0) {
			Picker("View", selection: $pane) {
				ForEach(AdaptiveMarkdownPanes.Pane.allCases) { Text($0.label).tag($0) }
			}
			.pickerStyle(.segmented)
			.padding(.horizontal)
			.padding(.vertical, 6)
			Divider()
			switch pane {
			case .rendered:
				RenderedMarkdownPane(
					text: text, context: context, scrollFraction: scrollFraction)
			case .source:
				SourceMarkdownPane(
					text: $text, selectedHeadingID: $selectedHeadingID,
					scrollFraction: $scrollFraction, context: context,
					onScrollFractionChanged: onScrollFractionChanged)
			}
		}
	}
}

private struct RegularMarkdownPanes: View {
	@Binding var text: String
	@Binding var selectedHeadingID: String?
	@Binding var scrollFraction: Double
	let context: MarkdownPaneContext
	var onScrollFractionChanged: ((Double) -> Void)?

	var body: some View {
		HStack(spacing: 0) {
			SourceMarkdownPane(
				text: $text, selectedHeadingID: $selectedHeadingID,
				scrollFraction: $scrollFraction, context: context,
				onScrollFractionChanged: onScrollFractionChanged)
			Divider()
			RenderedMarkdownPane(
				text: text, context: context, scrollFraction: scrollFraction)
		}
	}
}
#endif
