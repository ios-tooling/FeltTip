//
//  LineNumberRulerView.swift
//  MarkDownRange
//

#if os(macOS)
	import AppKit

final class LineNumberRulerView: NSRulerView {
	override var isFlipped: Bool { true }
	var textColor: NSColor = .secondaryLabelColor
	private weak var textView: NSTextView?
	private let gutterPadding: CGFloat = 8
	/// UTF-16 offsets of each hard line's first character, rebuilt lazily
	/// after `noteTextChanged()`. Drawing binary-searches this instead of
	/// walking layout from the top of the document — the walk made scrolling
	/// O(scroll position) per frame, visibly slow near the bottom of large
	/// documents.
	private var lineStarts: [Int] = []

	init(textView: NSTextView) {
		self.textView = textView
		super.init(scrollView: textView.enclosingScrollView!, orientation: .verticalRuler)
		clientView = textView
		ruleThickness = thickness(for: 1)
	}

	@available(*, unavailable)
	required init(coder: NSCoder) { fatalError() }

	/// The text changed: line starts are stale. Cheap to call repeatedly —
	/// the rebuild happens lazily on the next draw.
	func noteTextChanged() {
		lineStarts = []
		needsDisplay = true
	}

	/// The view scrolled or layout shifted; just redraw. (Kept separate from
	/// `noteTextChanged` so the per-scroll path does no text scanning.)
	func invalidateLineNumbers() {
		needsDisplay = true
	}

	override func drawHashMarksAndLabels(in rect: NSRect) {
		guard let textView, let layoutManager = textView.layoutManager,
			  let container = textView.textContainer,
			  let clipView = scrollView?.contentView else { return }
		rebuildLineStartsIfNeeded()
		guard !lineStarts.isEmpty else { return }

		let origin = textView.textContainerOrigin
		let scrollOffset = clipView.bounds.origin.y
		let visibleHeight = clipView.bounds.height
		// Only the fragments actually on screen — never walk from the top.
		let visibleRect = NSRect(x: 0, y: scrollOffset - origin.y, width: container.size.width, height: visibleHeight)
		let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
		guard glyphRange.length > 0 else { return }

		let attrs: [NSAttributedString.Key: Any] = [
			.font: numberFont(),
			.foregroundColor: textColor
		]

		layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragmentRect, _, _, fragmentGlyphs, _ in
			let charIndex = layoutManager.characterIndexForGlyph(at: fragmentGlyphs.location)
			let line = self.lineIndex(for: charIndex)
			// Wrapped continuations of a hard line carry no number.
			guard charIndex == self.lineStarts[line] else { return }
			let rulerY = fragmentRect.origin.y + origin.y - scrollOffset
			guard rulerY + fragmentRect.height >= 0, rulerY < visibleHeight else { return }

			let numStr = "\(line + 1)" as NSString
			let size = numStr.size(withAttributes: attrs)
			let x = self.ruleThickness - size.width - self.gutterPadding
			numStr.draw(at: NSPoint(x: x, y: rulerY + (fragmentRect.height - size.height) / 2), withAttributes: attrs)
		}
	}

	/// Index of the hard line containing the UTF-16 offset (binary search).
	private func lineIndex(for charIndex: Int) -> Int {
		var low = 0, high = lineStarts.count - 1
		while low < high {
			let mid = (low + high + 1) / 2
			if lineStarts[mid] <= charIndex { low = mid } else { high = mid - 1 }
		}
		return low
	}

	private func rebuildLineStartsIfNeeded() {
		guard lineStarts.isEmpty, let string = textView?.string else { return }
		var starts = [0]
		var offset = 0
		for unit in string.utf16 {
			offset += 1
			if unit == 0x0A { starts.append(offset) }
		}
		lineStarts = starts
		ruleThickness = thickness(for: starts.count)
	}

	private func numberFont() -> NSFont {
		let size = (textView?.font?.pointSize ?? 13) * 0.85
		return .monospacedSystemFont(ofSize: size, weight: .regular)
	}

	private func thickness(for lineCount: Int) -> CGFloat {
		let digits = max(2, String(max(1, lineCount)).count)
		let charWidth = numberFont().advancement(forGlyph: NSGlyph(48)).width  // '0'
		return CGFloat(digits) * charWidth + gutterPadding * 2
	}
}
#endif
