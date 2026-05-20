//
//  SnapshotReplayer.swift
//  MarkDownRangeTests
//

#if os(macOS)
import AppKit
import SwiftUI
@testable import MarkDownRange

/// Rebuilds the render context captured in a `SnapshotBundle` and produces
/// a fresh `NSImage` for pixel-comparison against the bundle's reference.
@MainActor
enum SnapshotReplayer {
	/// Render `bundle` and return the resulting bitmap. `settleSeconds`
	/// gives the async render task + scroll syncer time to land before the
	/// capture; bump it for snapshots with lots of remote images.
	static func render(_ bundle: SnapshotBundle, settleSeconds: TimeInterval = 4) async -> NSImage? {
		let size = bundle.metadata.contentSize
		guard size.width > 0, size.height > 0 else { return nil }
		let theme = themeForRecordedName(bundle.metadata.theme)
		let fontSize = CGFloat(bundle.metadata.fontSize)

		let root = ReplayRoot(
			text: bundle.source,
			theme: theme,
			fontSize: fontSize,
			scrollFraction: bundle.metadata.scrollFraction
		)
		let hostingView = NSHostingView(rootView: root)
		hostingView.frame = NSRect(origin: .zero, size: size)

		// Use a real (offscreen) window so SwiftUI `.task` modifiers and the
		// scroll syncer's bounds-change observers actually run; without a
		// window the FormattedMarkdownScreen render task never fires.
		let window = NSWindow(
			contentRect: hostingView.frame,
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.contentView = hostingView
		window.orderFront(nil)
		defer { window.orderOut(nil) }

		hostingView.layoutSubtreeIfNeeded()

		// Yield to the runloop in small chunks so the async parse + image
		// loads have a chance to complete before we cache the bitmap.
		let chunks = max(1, Int(settleSeconds * 10))
		for _ in 0..<chunks {
			try? await Task.sleep(for: .milliseconds(100))
		}

		guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
			return nil
		}
		hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
		let image = NSImage(size: hostingView.bounds.size)
		image.addRepresentation(rep)
		return image
	}

	/// AppTheme-named bundles came out of the recorder with an `AppTheme`
	/// rawValue. The replayer can't pull `AppTheme.theme` (Marker-only), so
	/// it maps onto the framework's bundled MarkdownTheme statics when the
	/// names line up and falls back to `.default` otherwise. Recorded
	/// bundles whose theme doesn't match here may diff in colors — the
	/// replayer test reports the drift so it's visible at review.
	private static func themeForRecordedName(_ name: String) -> MarkdownTheme {
		switch name {
		case "github": return .github
		case "sepia": return .sepia
		case "dark": return .dark
		default: return .default
		}
	}
}

private struct ReplayRoot: View {
	let text: String
	let theme: MarkdownTheme
	let fontSize: CGFloat
	let scrollFraction: Double

	@State private var selectedHeading: String?
	@State private var linkDisplay = LinkDisplayState()

	var body: some View {
		FormattedMarkdownScreen(
			text: text,
			selectedHeadingID: $selectedHeading,
			theme: theme,
			fontSize: fontSize,
			syncScrollFraction: scrollFraction
		)
		.environment(linkDisplay)
		.background(theme.backgroundColor)
	}
}
#endif
