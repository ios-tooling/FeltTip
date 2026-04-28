//
//  PassThroughHorizontalScroll.swift
//  MarkDownRange
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

// A horizontal scroll container that forwards vertically-dominant scroll
// events to its parent. SwiftUI's `ScrollView(.horizontal)` consumes scroll
// events on macOS even when the gesture is vertical, blocking the outer
// document scroll when the cursor is over a code block or wide table.
struct PassThroughHorizontalScroll<Content: View>: View {
	@ViewBuilder let content: () -> Content

	var body: some View {
		#if os(macOS)
		Representable(content: content())
		#else
		ScrollView(.horizontal, showsIndicators: false) { content() }
		#endif
	}
}

#if os(macOS)
private struct Representable<Content: View>: NSViewRepresentable {
	let content: Content

	func makeNSView(context: Context) -> PassThroughScrollView {
		let scrollView = PassThroughScrollView()
		scrollView.hasHorizontalScroller = false
		scrollView.hasVerticalScroller = false
		scrollView.drawsBackground = false
		scrollView.borderType = .noBorder
		scrollView.horizontalScrollElasticity = .allowed
		scrollView.verticalScrollElasticity = .none
		scrollView.autohidesScrollers = true

		let host = NSHostingView(rootView: content)
		host.sizingOptions = [.intrinsicContentSize]
		host.translatesAutoresizingMaskIntoConstraints = false
		scrollView.documentView = host

		NSLayoutConstraint.activate([
			host.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
			host.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
		])
		return scrollView
	}

	func updateNSView(_ nsView: PassThroughScrollView, context: Context) {
		if let host = nsView.documentView as? NSHostingView<Content> {
			host.rootView = content
			nsView.invalidateIntrinsicContentSize()
		}
	}
}

private final class PassThroughScrollView: NSScrollView {
	override var intrinsicContentSize: NSSize {
		if let host = documentView {
			let h = host.intrinsicContentSize.height
			if h > 0 {
				return NSSize(width: NSView.noIntrinsicMetric, height: h)
			}
		}
		return super.intrinsicContentSize
	}

	override func scrollWheel(with event: NSEvent) {
		if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
			super.scrollWheel(with: event)
		} else {
			nextResponder?.scrollWheel(with: event)
		}
	}
}
#endif
