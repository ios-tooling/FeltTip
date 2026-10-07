#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import FeltTip

@Suite("Raw editor scroll targets") @MainActor
struct MarkdownTextEditorScrollTargetTests {
	@Test("A fresh token reapplies an unchanged scroll fraction")
	func repeatedFractionWithFreshTokenScrollsAgain() {
		let editor = MarkdownTextEditor(
			text: .constant(""), selectedHeadingID: .constant(nil))
		let coordinator = MarkdownTextEditor.Coordinator(editor)
		let scrollView = NSScrollView(
			frame: NSRect(x: 0, y: 0, width: 700, height: 400))
		scrollView.documentView = FlippedDocumentView(
			frame: NSRect(x: 0, y: 0, width: 700, height: 4_000))
		scrollView.layoutSubtreeIfNeeded()

		let first = MarkdownScrollTarget(topFraction: 0.25, token: 1)
		coordinator.applyScrollTarget(first, to: scrollView)
		#expect(scrollFraction(in: scrollView).isApproximatelyEqual(to: 0.25))

		setScrollFraction(0.75, in: scrollView)
		coordinator.applyScrollTarget(first, to: scrollView)
		#expect(scrollFraction(in: scrollView).isApproximatelyEqual(to: 0.75))

		coordinator.applyScrollTarget(
			MarkdownScrollTarget(topFraction: 0.25, token: 2), to: scrollView)
		#expect(scrollFraction(in: scrollView).isApproximatelyEqual(to: 0.25))
	}

	@Test("A raw editor preserves its viewport through a width change")
	func rawViewportSurvivesResize() async throws {
		let source = (0..<1_600).map { index in
			"## Sector \(index)\n\nTransfer sentence \(index) records enough text to wrap after a narrow resize."
		}.joined(separator: "\n\n")
		var text = source
		var heading: String?
		let root = RawMarkdownScreen(
			text: Binding(get: { text }, set: { text = $0 }),
			selectedHeadingID: Binding(get: { heading }, set: { heading = $0 }),
			fontSize: 14,
			scrollTarget: MarkdownScrollTarget(topFraction: 0.65, token: 1))
		let hosting = NSHostingView(rootView: root)
		hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
		let window = NSWindow(
			contentRect: hosting.frame, styleMask: [.borderless],
			backing: .buffered, defer: false)
		defer { closeTestWindow(window) }
		window.contentView = hosting
		window.orderFront(nil)
		hosting.layoutSubtreeIfNeeded()

		let editor = try #require(try await waitForTextView(in: hosting))
		for _ in 0..<80 where !scrollFraction(in: editor.enclosingScrollView!).isApproximatelyEqual(to: 0.65) {
			hosting.layoutSubtreeIfNeeded()
			try await Task.sleep(for: .milliseconds(25))
		}

		window.setContentSize(NSSize(width: 430, height: 500))
		hosting.layoutSubtreeIfNeeded()
		try await Task.sleep(for: .milliseconds(100))
		// Sidebar/window animations can publish several intermediate widths. The
		// original pre-resize anchor must survive the whole sequence.
		window.setContentSize(NSSize(width: 620, height: 500))
		hosting.layoutSubtreeIfNeeded()
		try await Task.sleep(for: .milliseconds(1_800))

		let scrollView = try #require(editor.enclosingScrollView)
		#expect(scrollFraction(in: scrollView).isApproximatelyEqual(to: 0.65),
			"Raw resize drifted to \(scrollFraction(in: scrollView))")
	}

	private func waitForTextView(in view: NSView) async throws -> NSTextView? {
		for _ in 0..<120 {
			if let textView = findTextView(in: view) { return textView }
			try await Task.sleep(for: .milliseconds(25))
		}
		return nil
	}

	private func findTextView(in view: NSView) -> NSTextView? {
		if let textView = view as? NSTextView { return textView }
		for child in view.subviews {
			if let textView = findTextView(in: child) { return textView }
		}
		return nil
	}

	private func setScrollFraction(_ fraction: CGFloat, in scrollView: NSScrollView) {
		let span = max(0, (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height)
		scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: fraction * span))
		scrollView.reflectScrolledClipView(scrollView.contentView)
	}

	private func scrollFraction(in scrollView: NSScrollView) -> CGFloat {
		MarkdownScrollGeometry.fraction(
			originY: scrollView.contentView.bounds.origin.y,
			documentFrame: scrollView.documentView?.frame ?? .zero,
			visibleHeight: scrollView.contentView.bounds.height)
	}
}

private final class FlippedDocumentView: NSView {
	override var isFlipped: Bool { true }
}

private extension CGFloat {
	func isApproximatelyEqual(to expected: CGFloat) -> Bool {
		abs(self - expected) < 0.02
	}
}
#endif
