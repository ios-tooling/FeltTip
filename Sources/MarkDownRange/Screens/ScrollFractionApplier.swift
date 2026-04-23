//
//  ScrollFractionApplier.swift
//  MarkdownRendering
//

#if os(macOS)
import SwiftUI
import AppKit

public struct ScrollFractionSync: NSViewRepresentable {
	@Binding var fraction: Double
	let isSource: Bool

	public init(fraction: Binding<Double>, isSource: Bool) {
		self._fraction = fraction
		self.isSource = isSource
	}

	public func makeNSView(context: Context) -> NSView {
		let view = NSView(frame: .zero)
		view.isHidden = true
		DispatchQueue.main.async { context.coordinator.setup(from: view, isSource: isSource) }
		return view
	}

	public func updateNSView(_ nsView: NSView, context: Context) {
		guard !isSource, !context.coordinator.isLocalScroll else { return }
		guard fraction != context.coordinator.lastApplied else { return }
		context.coordinator.lastApplied = fraction
		context.coordinator.applyFraction(fraction)
	}

	public func makeCoordinator() -> Coordinator { Coordinator(binding: $fraction) }

	public class Coordinator: NSObject {
		var binding: Binding<Double>
		weak var scrollView: NSScrollView?
		var observer: Any?
		var lastApplied: Double = -1
		var isLocalScroll = false

		init(binding: Binding<Double>) { self.binding = binding }

		func setup(from view: NSView, isSource: Bool) {
			guard scrollView == nil else { return }
			var current: NSView? = view.superview
			while let v = current {
				if let sv = v as? NSScrollView { scrollView = sv; break }
				current = v.superview
			}
			guard let scrollView, isSource else { return }
			scrollView.contentView.postsBoundsChangedNotifications = true
			observer = NotificationCenter.default.addObserver(
				forName: NSView.boundsDidChangeNotification,
				object: scrollView.contentView,
				queue: .main
			) { [weak self] _ in self?.reportFraction() }
		}

		func reportFraction() {
			guard let scrollView else { return }
			let docHeight = scrollView.documentView?.frame.height ?? 0
			let visibleHeight = scrollView.contentView.bounds.height
			guard docHeight > visibleHeight else { return }
			let offset = scrollView.contentView.bounds.origin.y
			let f = min(1, max(0, offset / (docHeight - visibleHeight)))
			isLocalScroll = true
			binding.wrappedValue = f
			isLocalScroll = false
		}

		func applyFraction(_ fraction: Double) {
			guard let scrollView else { return }
			let docHeight = scrollView.documentView?.frame.height ?? 0
			let visibleHeight = scrollView.contentView.bounds.height
			let targetOffset = fraction * max(0, docHeight - visibleHeight)
			scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetOffset))
			scrollView.reflectScrolledClipView(scrollView.contentView)
		}

		deinit { if let obs = observer { NotificationCenter.default.removeObserver(obs) } }
	}
}

/// Reports scroll fraction changes from inside a scroll view's content.
/// Must be placed inside the ScrollView (not as an overlay) to find the correct NSScrollView.
public struct ScrollFractionReporter: NSViewRepresentable {
	let onChanged: (Double) -> Void

	public init(onChanged: @escaping (Double) -> Void) { self.onChanged = onChanged }

	public func makeNSView(context: Context) -> NSView {
		let view = ScrollReporterView()
		view.isHidden = true
		view.coordinator = context.coordinator
		return view
	}

	public func updateNSView(_ nsView: NSView, context: Context) {
		context.coordinator.onChanged = onChanged
	}

	public func makeCoordinator() -> Coordinator { Coordinator(onChanged: onChanged) }

	/// Custom NSView that hooks into viewDidMoveToWindow for reliable hierarchy detection.
	class ScrollReporterView: NSView {
		weak var coordinator: Coordinator?

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			if window != nil { coordinator?.setup(from: self) }
		}
	}

	public class Coordinator: NSObject {
		var onChanged: (Double) -> Void
		weak var scrollView: NSScrollView?
		var observer: Any?

		init(onChanged: @escaping (Double) -> Void) { self.onChanged = onChanged }

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
			) { [weak self] _ in self?.reportFraction() }
		}

		func reportFraction() {
			guard let scrollView else { return }
			let docHeight = scrollView.documentView?.frame.height ?? 0
			let visibleHeight = scrollView.contentView.bounds.height
			guard docHeight > visibleHeight else { return }
			let offset = scrollView.contentView.bounds.origin.y
			let f = min(1, max(0, offset / (docHeight - visibleHeight)))
			onChanged(f)
		}

		deinit { if let obs = observer { NotificationCenter.default.removeObserver(obs) } }
	}
}

public struct ScrollFractionReceiver: NSViewRepresentable {
	let fraction: Double

	public init(fraction: Double) { self.fraction = fraction }

	public func makeNSView(context: Context) -> NSView {
		let view = NSView(frame: .zero)
		view.isHidden = true
		return view
	}

	public func updateNSView(_ nsView: NSView, context: Context) {
		guard fraction != context.coordinator.lastFraction else { return }
		context.coordinator.lastFraction = fraction
		DispatchQueue.main.async {
			guard let scrollView = Self.findScrollView(from: nsView) else { return }
			let docHeight = scrollView.documentView?.frame.height ?? 0
			let visibleHeight = scrollView.contentView.bounds.height
			let target = fraction * max(0, docHeight - visibleHeight)
			scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
			scrollView.reflectScrolledClipView(scrollView.contentView)
		}
	}

	public func makeCoordinator() -> Coordinator { Coordinator() }
	public class Coordinator { var lastFraction: Double = -1 }

	private static func findScrollView(from view: NSView) -> NSScrollView? {
		var current: NSView? = view.superview
		while let v = current {
			if let sv = v as? NSScrollView { return sv }
			current = v.superview
		}
		return nil
	}
}
#endif
