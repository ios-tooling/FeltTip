//
//  AdaptiveMarkdownPanes.swift
//  FeltTip
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
	var onPaneChanged: ((MarkdownCompactPane) -> Void)?
	var initialScrollFraction: Double?
	var onScrollFractionChanged: ((Double) -> Void)?

	@State private var pane: MarkdownCompactPane
	@State private var scrollFraction: Double = 0
	@State private var didSeedScroll = false
	/// Bumped whenever the source pane should adopt `scrollFraction`: the
	/// initial seed and each compact switch back to it.
	@State private var sourceScrollToken = 0

	init(
		text: Binding<String>,
		selectedHeadingID: Binding<String?>,
		context: MarkdownPaneContext,
		initialPane: MarkdownCompactPane,
		onPaneChanged: ((MarkdownCompactPane) -> Void)?,
		initialScrollFraction: Double?,
		onScrollFractionChanged: ((Double) -> Void)?
	) {
		_text = text
		_selectedHeadingID = selectedHeadingID
		self.context = context
		self.onPaneChanged = onPaneChanged
		self.initialScrollFraction = initialScrollFraction
		self.onScrollFractionChanged = onScrollFractionChanged
		_pane = State(initialValue: initialPane)
	}

	var body: some View {
		Group {
			if sizeClass == .compact {
				CompactMarkdownPanes(
					pane: $pane, text: $text, selectedHeadingID: $selectedHeadingID,
					scrollFraction: $scrollFraction, sourceScrollTarget: sourceScrollTarget,
					context: context, onScrollFractionChanged: onScrollFractionChanged)
			} else {
				RegularMarkdownPanes(
					text: $text, selectedHeadingID: $selectedHeadingID,
					scrollFraction: $scrollFraction, sourceScrollTarget: sourceScrollTarget,
					context: context, onScrollFractionChanged: onScrollFractionChanged)
			}
		}
		.onAppear {
			guard !didSeedScroll, let initialScrollFraction else { return }
			didSeedScroll = true
			scrollFraction = initialScrollFraction
			sourceScrollToken += 1
		}
		.onChange(of: pane) { _, pane in
			onPaneChanged?(pane)
			if pane == .source { sourceScrollToken += 1 }
		}
	}

	private var sourceScrollTarget: MarkdownScrollTarget {
		MarkdownScrollTarget(topFraction: CGFloat(scrollFraction), token: sourceScrollToken)
	}
}

private struct CompactMarkdownPanes: View {
	@Binding var pane: MarkdownCompactPane
	@Binding var text: String
	@Binding var selectedHeadingID: String?
	@Binding var scrollFraction: Double
	let sourceScrollTarget: MarkdownScrollTarget
	let context: MarkdownPaneContext
	var onScrollFractionChanged: ((Double) -> Void)?

	var body: some View {
		VStack(spacing: 0) {
			Picker("View", selection: $pane) {
				ForEach(MarkdownCompactPane.allCases) { Text($0.label).tag($0) }
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
					scrollFraction: $scrollFraction, scrollTarget: sourceScrollTarget,
					context: context, onScrollFractionChanged: onScrollFractionChanged)
			}
		}
	}
}

private struct RegularMarkdownPanes: View {
	@Binding var text: String
	@Binding var selectedHeadingID: String?
	@Binding var scrollFraction: Double
	let sourceScrollTarget: MarkdownScrollTarget
	let context: MarkdownPaneContext
	var onScrollFractionChanged: ((Double) -> Void)?

	var body: some View {
		HStack(spacing: 0) {
			SourceMarkdownPane(
				text: $text, selectedHeadingID: $selectedHeadingID,
				scrollFraction: $scrollFraction, scrollTarget: sourceScrollTarget,
				context: context, onScrollFractionChanged: onScrollFractionChanged)
			Divider()
			RenderedMarkdownPane(
				text: text, context: context, scrollFraction: scrollFraction)
		}
	}
}
#endif
