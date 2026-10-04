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

	private func setScrollFraction(_ fraction: CGFloat, in scrollView: NSScrollView) {
		let span = max(0, (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height)
		scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: fraction * span))
		scrollView.reflectScrolledClipView(scrollView.contentView)
	}

	private func scrollFraction(in scrollView: NSScrollView) -> CGFloat {
		let span = (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height
		return span > 0 ? scrollView.contentView.bounds.origin.y / span : 0
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
