#if os(macOS)
import AppKit
@testable import FeltTip

extension NSTextView {
	/// The raw editor's viewport as the host sees it: the top line's share of
	/// the document's lines. TextKit 2 only estimates pixel height (and refines
	/// the estimate as it lays out), so the editor reports and restores line
	/// fractions; tests compare against those, with the ends pinned like the
	/// editor pins them. Falls back to the pixel fraction when nothing is laid
	/// out at the top edge.
	@MainActor var lineScrollFraction: Double {
		guard let scrollView = enclosingScrollView else { return 0 }
		let clip = scrollView.contentView
		let pixel = MarkdownScrollGeometry.fraction(
			originY: clip.bounds.origin.y,
			documentFrame: scrollView.documentView?.frame ?? .zero,
			visibleHeight: clip.bounds.height)
		let top = clip.convert(CGPoint(x: clip.bounds.minX, y: clip.bounds.minY), to: self)
		let origin = textContainerOrigin
		guard let offset = sourceCharacterOffset(at: CGPoint(x: origin.x, y: max(origin.y, top.y))) else {
			return pixel
		}
		let index = MarkdownLineIndex(text: string)
		let lineCount = index.starts.count
		guard lineCount > 1, offset > 0 else { return 0 }
		guard pixel < 0.999 else { return 1 }
		return Double(index.position(at: offset).line) / Double(lineCount - 1)
	}
}
#endif
