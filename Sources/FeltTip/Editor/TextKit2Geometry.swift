//
//  TextKit2Geometry.swift
//  FeltTip
//
//  Position lookups for the raw editor on a TextKit 2 `NSTextView`.
//
//  The raw editor stays on TextKit 2 so that opening a multi-megabyte
//  document lays out only the viewport. Every geometry question the editor
//  asks — where is this range, which character is under this point, what is
//  the caret's line rectangle — therefore goes through `NSTextLayoutManager`.
//  Reading `NSTextView.layoutManager` on such a view would silently convert
//  it to TextKit 1 and lay the whole document out, so nothing here touches
//  it; a TextKit 1 view (only ever a test fixture) takes the fallback path
//  through `textKit1LayoutManager`.
//
//  Rectangles are returned in the text view's own coordinate space (text
//  container coordinates plus `textContainerOrigin`), matching what the
//  TextKit 1 code used to produce, and points are taken the same way.
//

#if os(macOS)
import AppKit

extension NSTextContentManager {
	/// The UTF-16 character offset of `location` from the start of the document.
	func characterOffset(of location: NSTextLocation) -> Int {
		offset(from: documentRange.location, to: location)
	}

	/// The document location at a UTF-16 offset, or nil when out of range.
	func location(atCharacterOffset offset: Int) -> NSTextLocation? {
		location(documentRange.location, offsetBy: offset)
	}

	/// The `NSTextRange` covering a UTF-16 character range, or nil when any
	/// part of it lies outside the document.
	func textRange(for range: NSRange) -> NSTextRange? {
		guard range.location != NSNotFound,
			  let start = location(atCharacterOffset: range.location),
			  let end = location(start, offsetBy: range.length) else { return nil }
		return NSTextRange(location: start, end: end)
	}

	/// The UTF-16 character range of a text range.
	func characterRange(for textRange: NSTextRange) -> NSRange {
		NSRange(
			location: characterOffset(of: textRange.location),
			length: offset(from: textRange.location, to: textRange.endLocation))
	}
}

extension NSTextLayoutManager {
	/// The laid-out fragment containing the character at `offset`, laying it
	/// out first. The document's end location belongs to no fragment, so a
	/// caret at EOF resolves to the final one.
	///
	/// Deep in a document nobody has scrolled to, TextKit 2 hands back a
	/// fragment whose frame is only an estimate (and `ensureLayout` over an
	/// empty range does nothing). Scrolling to an estimate lays out text
	/// there, which refines the estimate, which moves the target — a viewport
	/// replay chasing it laid out an entire 20 MB document. So lay out the
	/// fragment's own range and return the laid-out one.
	func layoutFragment(atCharacterOffset offset: Int) -> NSTextLayoutFragment? {
		guard let contentManager = textContentManager,
			  let location = contentManager.location(atCharacterOffset: offset) else { return nil }
		func fragment(at location: NSTextLocation) -> NSTextLayoutFragment? {
			var found: NSTextLayoutFragment?
			enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) { fragment in
				found = fragment
				return false
			}
			if found == nil {
				enumerateTextLayoutFragments(from: location, options: [.ensuresLayout, .reverse]) { fragment in
					found = fragment
					return false
				}
			}
			return found
		}
		guard let candidate = fragment(at: location) else { return nil }
		guard candidate.state != .layoutAvailable else { return candidate }
		ensureLayout(for: candidate.rangeInElement)
		return fragment(at: location) ?? candidate
	}
}

extension NSTextView {
	/// The union of the rectangles a character range occupies, in text view
	/// coordinates. A collapsed range yields its caret line's rectangle.
	/// Lays the range out if needed; nil only when the view has no layout
	/// machinery or the range is outside the document.
	func sourceRect(for range: NSRange) -> CGRect? {
		if let textLayoutManager {
			guard range.length > 0 else { return sourceLineRect(atCharacterOffset: range.location) }
			guard let contentManager = textLayoutManager.textContentManager,
				  let textRange = contentManager.textRange(for: range) else { return nil }
			textLayoutManager.ensureLayout(for: textRange)
			var union: CGRect?
			textLayoutManager.enumerateTextSegments(
				in: textRange, type: .standard, options: [.rangeNotRequired]
			) { _, frame, _, _ in
				union = union.map { $0.union(frame) } ?? frame
				return true
			}
			guard let union else { return sourceLineRect(atCharacterOffset: range.location) }
			return union.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
		}
		guard let layoutManager = textKit1LayoutManager, let textContainer else { return nil }
		layoutManager.ensureLayout(forCharacterRange: range)
		let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
		return layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
			.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
	}

	/// The rectangle of the line fragment holding the character at `offset`
	/// (the caret line, for an insertion point), in text view coordinates.
	func sourceLineRect(atCharacterOffset offset: Int) -> CGRect? {
		if let textLayoutManager {
			guard let contentManager = textLayoutManager.textContentManager,
				  let fragment = textLayoutManager.layoutFragment(atCharacterOffset: offset) else { return nil }
			let fragmentStart = contentManager.characterOffset(of: fragment.rangeInElement.location)
			let local = offset - fragmentStart
			let lines = fragment.textLineFragments
			let line = lines.first { local < NSMaxRange($0.characterRange) } ?? lines.last
			let bounds = line?.typographicBounds
				?? CGRect(origin: .zero, size: fragment.layoutFragmentFrame.size)
			return bounds
				.offsetBy(dx: fragment.layoutFragmentFrame.minX, dy: fragment.layoutFragmentFrame.minY)
				.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
		}
		guard let layoutManager = textKit1LayoutManager else { return nil }
		let glyphRange = layoutManager.glyphRange(
			forCharacterRange: NSRange(location: offset, length: 0), actualCharacterRange: nil)
		guard glyphRange.location < layoutManager.numberOfGlyphs || layoutManager.numberOfGlyphs == 0 else {
			return nil
		}
		return layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
			.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
	}

	/// The UTF-16 offset of the character drawn at `point` (text view
	/// coordinates), or nil when nothing is laid out there yet.
	func sourceCharacterOffset(at point: CGPoint) -> Int? {
		let containerPoint = CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
		if let textLayoutManager {
			guard let contentManager = textLayoutManager.textContentManager,
				  var fragment = textLayoutManager.textLayoutFragment(for: containerPoint) else { return nil }
			// The point may fall in a fragment whose position is still an
			// estimate; lay it out so its line fragments exist to hit-test.
			if fragment.state != .layoutAvailable {
				textLayoutManager.ensureLayout(for: fragment.rangeInElement)
				fragment = textLayoutManager.textLayoutFragment(for: containerPoint) ?? fragment
			}
			let fragmentStart = contentManager.characterOffset(of: fragment.rangeInElement.location)
			let local = CGPoint(
				x: containerPoint.x - fragment.layoutFragmentFrame.minX,
				y: containerPoint.y - fragment.layoutFragmentFrame.minY)
			let lines = fragment.textLineFragments
			guard let line = lines.first(where: { $0.typographicBounds.maxY > local.y }) ?? lines.last else {
				return fragmentStart
			}
			return fragmentStart + line.characterIndex(for: local)
		}
		guard let layoutManager = textKit1LayoutManager, let textContainer else { return nil }
		let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
		guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
		return layoutManager.characterIndexForGlyph(at: glyphIndex)
	}
}
#endif
