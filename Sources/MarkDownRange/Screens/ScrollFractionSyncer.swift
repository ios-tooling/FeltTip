//
//  ScrollFractionSyncer.swift
//  MarkDownRange
//
//  Two-way scroll-fraction sync for a SwiftUI ScrollView. Inserted as a hidden
//  helper view *inside* the ScrollView's content; finds its enclosing
//  NSScrollView, observes user scrolls (reports them), and applies external
//  fractions (without echoing them back as new user scrolls).
//
//  Holds a single `isApplying` flag in the Coordinator that's released on the
//  next main-queue tick — the bounds-change notification we observe is queued
//  on `.main`, so the flag has to outlive the synchronous scroll call to cover
//  the deferred observer block. Otherwise a programmatic scroll would echo
//  back as if the user had scrolled, and the two panes would ping-pong.
//

#if os(macOS)
import SwiftUI
import AppKit

public struct ScrollFractionSyncer: NSViewRepresentable {
	let incoming: Double?
	let onChanged: (Double) -> Void

	public init(incoming: Double?, onChanged: @escaping (Double) -> Void) {
		self.incoming = incoming
		self.onChanged = onChanged
	}

	public func makeNSView(context: Context) -> NSView {
		let view = SyncerHostView()
		view.isHidden = true
		view.coordinator = context.coordinator
		return view
	}

	public func updateNSView(_ view: NSView, context: Context) {
		context.coordinator.onChanged = onChanged
		guard let incoming, incoming != context.coordinator.lastApplied else { return }
		context.coordinator.lastApplied = incoming
		context.coordinator.applyFraction(incoming)
	}

	public func makeCoordinator() -> Coordinator { Coordinator(onChanged: onChanged) }

	private final class SyncerHostView: NSView {
		weak var coordinator: Coordinator?

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			if window != nil { coordinator?.setup(from: self) }
		}
	}

	@MainActor
	public final class Coordinator: NSObject {
		var onChanged: (Double) -> Void
		weak var scrollView: NSScrollView?
		var observer: Any?
		var lastApplied: Double = -1
		var isApplying = false

		init(onChanged: @escaping (Double) -> Void) { self.onChanged = onChanged }

		deinit {
			MainActor.assumeIsolated {
				if let obs = observer { NotificationCenter.default.removeObserver(obs) }
			}
		}

		func setup(from view: NSView) {
			guard scrollView == nil else { return }
			var current: NSView? = view.superview
			while let v = current {
				if let sv = v as? NSScrollView { scrollView = sv; break }
				current = v.superview
			}
			guard let scrollView, observer == nil else { return }
			scrollView.contentView.postsBoundsChangedNotifications = true
			observer = NotificationCenter.default.addObserver(
				forName: NSView.boundsDidChangeNotification,
				object: scrollView.contentView,
				queue: .main
			) { [weak self] _ in
				guard let self, !self.isApplying else { return }
				self.reportFraction()
			}
		}

		private func reportFraction() {
			guard let scrollView else { return }
			let docHeight = scrollView.documentView?.frame.height ?? 0
			let visibleHeight = scrollView.contentView.bounds.height
			guard docHeight > visibleHeight else { return }
			let offset = scrollView.contentView.bounds.origin.y
			let f = min(1, max(0, offset / (docHeight - visibleHeight)))
			lastApplied = f
			onChanged(f)
		}

		func applyFraction(_ fraction: Double) {
			guard let scrollView else { return }
			isApplying = true
			let docHeight = scrollView.documentView?.frame.height ?? 0
			let visibleHeight = scrollView.contentView.bounds.height
			let target = fraction * max(0, docHeight - visibleHeight)
			scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
			scrollView.reflectScrolledClipView(scrollView.contentView)
			// Bounds-change observers queued on .main fire after this method
			// returns. Release the suppression flag on the next main-queue tick
			// (FIFO behind the queued observer) so the echoed scroll is dropped
			// but genuine subsequent user scrolls still report.
			Task { @MainActor [weak self] in
				self?.isApplying = false
			}
		}
	}
}
#endif
