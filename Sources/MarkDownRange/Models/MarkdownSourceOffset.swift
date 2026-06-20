//
//  MarkdownSourceOffset.swift
//  MarkDownRange
//
//  Per-run attribute recording where a rendered run's text begins in the raw
//  Markdown source (as a UTF-16 / NSString offset). Written during parsing when
//  source-offset tracking is enabled, and read back when translating edits made
//  in the styled editor into edits on the Markdown source.
//

import Foundation

public enum MarkdownSourceOffsetAttribute: AttributedStringKey {
	public typealias Value = Int
	public static let name = "MarkDownRangeSourceOffset"
}

/// Converts swift-markdown source locations (1-based line, 1-based **UTF-8**
/// column) into UTF-16 offsets in the parsed string, so edits can be applied
/// with NSString / NSRange semantics. Builds a byte→UTF-16 table once, then
/// answers lookups in O(1).
struct SourceOffsetConverter {
	private let lineStartBytes: [Int]   // UTF-8 byte offset of each line's start
	private let byteToUTF16: [Int]      // UTF-8 byte offset → UTF-16 offset
	/// Added to every returned offset. Lets the parsed string be a suffix of
	/// the caller's source (e.g. the body after frontmatter was stripped) while
	/// the offsets still address the full source.
	private let baseOffset: Int
	/// Optional processed-UTF16 → source-UTF16 map, for when the parsed string
	/// is a preprocessed form of the source rather than the raw source. Nil
	/// means the parsed string *is* the source.
	private let map: [Int]?

	init(_ source: String, baseOffset: Int = 0, map: [Int]? = nil) {
		self.baseOffset = baseOffset
		self.map = map
		var lineStarts = [0]
		var byteMap: [Int] = []
		byteMap.reserveCapacity(source.utf8.count + 1)
		var utf16Cursor = 0
		for scalar in source.unicodeScalars {
			let v = scalar.value
			let utf8Length = v < 0x80 ? 1 : v < 0x800 ? 2 : v < 0x10000 ? 3 : 4
			for _ in 0..<utf8Length { byteMap.append(utf16Cursor) }
			if v == 0x0A { lineStarts.append(byteMap.count) }   // next line starts after "\n"
			utf16Cursor += v > 0xFFFF ? 2 : 1
		}
		byteMap.append(utf16Cursor)
		lineStartBytes = lineStarts
		byteToUTF16 = byteMap
	}

	func utf16Offset(line: Int, column: Int) -> Int? {
		guard line >= 1, line <= lineStartBytes.count else { return nil }
		let byte = lineStartBytes[line - 1] + (column - 1)
		guard byte >= 0, byte < byteToUTF16.count else { return nil }
		let processedOffset = byteToUTF16[byte]
		let sourceOffset: Int
		if let map {
			sourceOffset = processedOffset < map.count ? map[processedOffset] : (map.last ?? processedOffset)
		} else {
			sourceOffset = processedOffset
		}
		return sourceOffset + baseOffset
	}
}
