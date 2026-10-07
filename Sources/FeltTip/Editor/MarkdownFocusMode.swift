import Foundation

/// Shared paragraph selection semantics for the raw editors' focus mode.
enum MarkdownFocusMode {
	static func focusedRange(in text: String, selection: NSRange) -> NSRange {
		focusedRange(in: text as NSString, selection: selection)
	}

	/// `NSTextStorage.mutableString` is a live proxy, so the macOS editor can
	/// pass it without bridging the whole document on every caret move.
	static func focusedRange(in source: NSString, selection: NSRange) -> NSRange {
		guard source.length > 0 else { return NSRange(location: 0, length: 0) }
		let location = min(max(0, selection.location), source.length)
		let end = min(source.length, location + max(0, selection.length))
		// paragraphRange(for:) treats an insertion point at EOF correctly, but
		// requires its range to stay inside the string.
		let startProbe = min(location, source.length - 1)
		let endProbe = min(max(startProbe, end), source.length - 1)
		return source.paragraphRange(for: NSRange(
			location: startProbe,
			length: max(0, endProbe - startProbe)))
	}
}
