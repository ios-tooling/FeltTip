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
	var scrollTarget: MarkdownScrollTarget?
	var onScrollFractionChanged: ((Double) -> Void)?

	@State private var pane: MarkdownCompactPane
	@State private var scrollFraction: Double
	// Keep each drive independent: a report must only drive the OTHER pane.
	@State private var sourceScrollTarget: MarkdownScrollTarget
	@State private var renderedScrollTarget: MarkdownScrollTarget
	@State private var scrollToken = 0
	@State private var lastHostScrollToken: Int?

	init(
		text: Binding<String>,
		selectedHeadingID: Binding<String?>,
		context: MarkdownPaneContext,
		initialPane: MarkdownCompactPane,
		onPaneChanged: ((MarkdownCompactPane) -> Void)?,
		initialScrollFraction: Double?,
		scrollTarget: MarkdownScrollTarget? = nil,
		onScrollFractionChanged: ((Double) -> Void)?
	) {
		_text = text
		_selectedHeadingID = selectedHeadingID
		self.context = context
		self.onPaneChanged = onPaneChanged
		self.scrollTarget = scrollTarget
		let fraction = Double(scrollTarget?.topFraction ?? CGFloat(initialScrollFraction ?? 0))
		_scrollFraction = State(initialValue: fraction)
		let seed = MarkdownScrollTarget(topFraction: CGFloat(fraction), token: 0)
		_sourceScrollTarget = State(initialValue: seed)
		_renderedScrollTarget = State(initialValue: seed)
		_lastHostScrollToken = State(initialValue: scrollTarget?.token)
		self.onScrollFractionChanged = onScrollFractionChanged
		_pane = State(initialValue: initialPane)
	}

	var body: some View {
		Group {
			if sizeClass == .compact {
				CompactMarkdownPanes(
					pane: $pane, text: $text, selectedHeadingID: $selectedHeadingID,
					scrollFraction: scrollFraction, sourceScrollTarget: sourceScrollTarget,
					renderedScrollTarget: renderedScrollTarget,
					context: context, onScroll: didScroll)
			} else {
				RegularMarkdownPanes(
					text: $text, selectedHeadingID: $selectedHeadingID,
					scrollFraction: scrollFraction, sourceScrollTarget: sourceScrollTarget,
					renderedScrollTarget: renderedScrollTarget,
					context: context, onScroll: didScroll)
			}
		}
		.onChange(of: scrollTarget) { _, target in
			guard let target, target.token != lastHostScrollToken else { return }
			lastHostScrollToken = target.token
			scrollFraction = Double(target.topFraction)
			let drive = nextTarget(scrollFraction)
			sourceScrollTarget = drive
			renderedScrollTarget = drive
		}
		.onChange(of: pane) { _, pane in
			onPaneChanged?(pane)
			drive(pane, to: scrollFraction)
		}
	}

	private func nextTarget(_ fraction: Double) -> MarkdownScrollTarget {
		scrollToken &+= 1
		return MarkdownScrollTarget(topFraction: CGFloat(fraction), token: scrollToken)
	}

	private func drive(_ pane: MarkdownCompactPane, to fraction: Double) {
		let target = nextTarget(fraction)
		switch pane {
		case .source: sourceScrollTarget = target
		case .rendered: renderedScrollTarget = target
		}
	}

	private func didScroll(_ pane: MarkdownCompactPane, fraction: Double) {
		scrollFraction = fraction
		onScrollFractionChanged?(fraction)
		drive(pane == .source ? .rendered : .source, to: fraction)
	}
}

private struct CompactMarkdownPanes: View {
	@Binding var pane: MarkdownCompactPane
	@Binding var text: String
	@Binding var selectedHeadingID: String?
	let scrollFraction: Double
	let sourceScrollTarget: MarkdownScrollTarget
	let renderedScrollTarget: MarkdownScrollTarget
	let context: MarkdownPaneContext
	var onScroll: (MarkdownCompactPane, Double) -> Void

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
					text: text, context: context, scrollFraction: scrollFraction,
					scrollTarget: renderedScrollTarget,
					onScrollFractionChanged: { onScroll(.rendered, $0) })
			case .source:
				SourceMarkdownPane(
					text: $text, selectedHeadingID: $selectedHeadingID,
					scrollTarget: sourceScrollTarget,
					context: context, onScrollFractionChanged: { onScroll(.source, $0) })
			}
		}
	}
}

private struct RegularMarkdownPanes: View {
	@Binding var text: String
	@Binding var selectedHeadingID: String?
	let scrollFraction: Double
	let sourceScrollTarget: MarkdownScrollTarget
	let renderedScrollTarget: MarkdownScrollTarget
	let context: MarkdownPaneContext
	var onScroll: (MarkdownCompactPane, Double) -> Void

	var body: some View {
		HStack(spacing: 0) {
			SourceMarkdownPane(
				text: $text, selectedHeadingID: $selectedHeadingID,
				scrollTarget: sourceScrollTarget,
				context: context, onScrollFractionChanged: { onScroll(.source, $0) })
			Divider()
			RenderedMarkdownPane(
				text: text, context: context, scrollFraction: scrollFraction,
					scrollTarget: renderedScrollTarget,
					onScrollFractionChanged: { onScroll(.rendered, $0) })
		}
	}
}
#endif
