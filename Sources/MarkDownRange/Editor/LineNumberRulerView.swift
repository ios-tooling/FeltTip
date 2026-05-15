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
	private var lastLineCount = 0

	init(textView: NSTextView) {
		self.textView = textView
		super.init(scrollView: textView.enclosingScrollView!, orientation: .verticalRuler)
		clientView = textView
		ruleThickness = thickness(for: 1)
	}

	@available(*, unavailable)
	required init(coder: NSCoder) { fatalError() }

	func invalidateLineNumbers() {
		let count = lineCount()
		if count != lastLineCount {
			lastLineCount = count
			ruleThickness = thickness(for: count)
		}
		needsDisplay = true
	}

	override func drawHashMarksAndLabels(in rect: NSRect) {
		guard let textView, let layoutManager = textView.layoutManager,
			  let clipView = scrollView?.contentView else { return }

		let string = textView.string as NSString
		let origin = textView.textContainerOrigin
		let scrollOffset = clipView.bounds.origin.y
		let visibleHeight = clipView.bounds.height
		let allGlyphs = NSRange(location: 0, length: layoutManager.numberOfGlyphs)
		guard allGlyphs.length > 0 else { return }

		let attrs: [NSAttributedString.Key: Any] = [
			.font: numberFont(),
			.foregroundColor: textColor
		]

		var lineNumber = 1
		var lastParaStart: Int = -1
		layoutManager.enumerateLineFragments(forGlyphRange: allGlyphs) { fragmentRect, _, _, glyphRange, stop in
			let charIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)
			let paraRange = string.paragraphRange(for: NSRange(location: charIndex, length: 0))
			guard paraRange.location != lastParaStart else { return }
			lastParaStart = paraRange.location

			let docY = fragmentRect.origin.y + origin.y
			let rulerY = docY - scrollOffset

			if rulerY >= visibleHeight {
				// Everything past here is below the visible window, so don't
				// keep walking the rest of the document on every scroll tick.
				stop.pointee = true
				return
			}

			guard rulerY + fragmentRect.height >= 0 else {
				lineNumber += 1
				return
			}

			let numStr = "\(lineNumber)" as NSString
			let size = numStr.size(withAttributes: attrs)
			let x = self.ruleThickness - size.width - self.gutterPadding
			numStr.draw(at: NSPoint(x: x, y: rulerY + (fragmentRect.height - size.height) / 2), withAttributes: attrs)
			lineNumber += 1
		}
	}

	private func lineCount() -> Int {
		guard let string = textView?.string else { return 0 }
		var count = 1
		for unit in string.utf8 where unit == 0x0A { count += 1 }
		return count
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
