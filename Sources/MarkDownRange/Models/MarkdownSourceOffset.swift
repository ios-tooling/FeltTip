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
	/// UTF-8 byte offset → UTF-16 offset. Nil when the source is ASCII, where
	/// the mapping is identity and a document-sized Int table would be waste.
	private let byteToUTF16: [Int]?
	private let processedUTF16: [UInt16]
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
		processedUTF16 = Array(source.utf16)
		var lineStarts = [0]
		var isASCII = true
		for (offset, byte) in source.utf8.enumerated() {
			if byte >= 0x80 { isASCII = false }
			if byte == 0x0A { lineStarts.append(offset + 1) }
		}
		lineStartBytes = lineStarts
		guard !isASCII else {
			byteToUTF16 = nil
			return
		}

		var byteMap: [Int] = []
		byteMap.reserveCapacity(source.utf8.count + 1)
		var utf16Cursor = 0
		for scalar in source.unicodeScalars {
			let v = scalar.value
			let utf8Length = v < 0x80 ? 1 : v < 0x800 ? 2 : v < 0x10000 ? 3 : 4
			for _ in 0..<utf8Length { byteMap.append(utf16Cursor) }
			utf16Cursor += v > 0xFFFF ? 2 : 1
		}
		byteMap.append(utf16Cursor)
		byteToUTF16 = byteMap
	}

	/// Test-visible allocation invariant for the common ASCII document path.
	var usesIdentityByteMapping: Bool { byteToUTF16 == nil }

	func utf16Offset(line: Int, column: Int) -> Int? {
		guard let processedOffset = processedUTF16(line: line, column: column) else { return nil }
		return mapToSource(processedOffset) + baseOffset
	}

	/// Source offset for a rendered run spanning `lower..<upper` whose rendered
	/// text is `renderedLength` UTF-16 units — but only when that text maps 1:1
	/// onto the source: same length in the processed text, and a contiguous
	/// stretch of surviving source characters. Runs that fail (entity
	/// references, preprocessor rewrites) return nil and go unstamped, so the
	/// editors treat them as unmappable instead of splicing at drifted offsets.
	func verbatimUTF16Offset(lowerLine: Int, lowerColumn: Int, upperLine: Int, upperColumn: Int, renderedLength: Int) -> Int? {
		guard let pLow = processedUTF16(line: lowerLine, column: lowerColumn),
			  let pUp = processedUTF16(line: upperLine, column: upperColumn),
			  pUp - pLow == renderedLength else { return nil }
		return verbatimSourceOffset(processedOffset: pLow, length: renderedLength)
	}

	/// Text-node variant of `verbatimUTF16Offset`. In addition to checking the
	/// reported range's length, verify that it contains the text being stamped.
	/// swift-markdown reports lazy list-continuation lines at the list content's
	/// virtual indentation (typically three columns right of their real source
	/// location). If the reported position is wrong, recover only when the
	/// rendered text occurs exactly once across the node's source lines.
	func verbatimUTF16Offset(
		lowerLine: Int,
		lowerColumn: Int,
		upperLine: Int,
		upperColumn: Int,
		rendered: String
	) -> Int? {
		let renderedUTF16 = rendered.utf16
		let renderedLength = renderedUTF16.count
		guard let pLow = processedUTF16(line: lowerLine, column: lowerColumn),
			  let pUp = processedUTF16(line: upperLine, column: upperColumn) else { return nil }
		if pUp - pLow == renderedLength,
		   processedUTF16[pLow..<pUp].elementsEqual(renderedUTF16) {
			return verbatimSourceOffset(processedOffset: pLow, length: renderedLength)
		}

		guard !renderedUTF16.isEmpty,
			  let searchStart = processedLineStart(lowerLine),
			  let searchEnd = processedLineEnd(upperLine),
			  searchEnd - searchStart >= renderedLength else { return nil }
		var match: Int?
		for candidate in searchStart...(searchEnd - renderedLength) {
			guard processedUTF16[candidate..<(candidate + renderedLength)]
				.elementsEqual(renderedUTF16),
				  verbatimSourceOffset(processedOffset: candidate, length: renderedLength) != nil else { continue }
			if match != nil { return nil }
			match = candidate
		}
		return match.flatMap {
			verbatimSourceOffset(processedOffset: $0, length: renderedLength)
		}
	}

	/// Inline-code nodes have no child `Text` range: swift-markdown reports the
	/// whole span, including its backtick delimiters. Stamp the rendered code
	/// only when the text between those delimiters is an exact, contiguous
	/// source substring. One symmetric padding space may be skipped because
	/// CommonMark removes it; other normalization such as folded newlines
	/// deliberately remains unstamped.
	func verbatimInlineCodeUTF16Offset(
		lowerLine: Int,
		lowerColumn: Int,
		upperLine: Int,
		upperColumn: Int,
		rendered: String
	) -> Int? {
		guard let pLow = processedUTF16(line: lowerLine, column: lowerColumn),
			  let pUp = processedUTF16(line: upperLine, column: upperColumn),
			  pLow >= 0, pUp <= processedUTF16.count, pUp > pLow else { return nil }

		var delimiterLength = 0
		while pLow + delimiterLength < pUp,
			  processedUTF16[pLow + delimiterLength] == 0x60 {
			delimiterLength += 1
		}
		guard delimiterLength > 0, pUp - pLow >= delimiterLength * 2 else { return nil }
		for index in 0..<delimiterLength where processedUTF16[pUp - 1 - index] != 0x60 {
			return nil
		}

		let contentStart = pLow + delimiterLength
		let contentEnd = pUp - delimiterLength
		let renderedUTF16 = Array(rendered.utf16)
		if contentEnd - contentStart == renderedUTF16.count,
		   processedUTF16[contentStart..<contentEnd].elementsEqual(renderedUTF16) {
			return verbatimSourceOffset(processedOffset: contentStart, length: renderedUTF16.count)
		}
		// A code span padded to keep leading/trailing backticks unambiguous
		// renders without one surrounding space. Its visible content is still
		// a verbatim source slice one character farther in.
		let paddedStart = contentStart + 1
		let paddedEnd = contentEnd - 1
		guard contentEnd - contentStart >= 2,
			  processedUTF16[contentStart] == 0x20,
			  processedUTF16[contentEnd - 1] == 0x20,
			  paddedEnd - paddedStart == renderedUTF16.count,
			  processedUTF16[paddedStart..<paddedEnd].elementsEqual(renderedUTF16) else { return nil }
		return verbatimSourceOffset(processedOffset: paddedStart, length: renderedUTF16.count)
	}

	private func verbatimSourceOffset(processedOffset: Int, length: Int) -> Int? {
		if let map {
			guard processedOffset + length <= map.count else { return nil }
			let base = map[processedOffset]
			for k in 0..<length where map[processedOffset + k] != base + k { return nil }
		}
		return mapToSource(processedOffset) + baseOffset
	}

	private func processedUTF16(line: Int, column: Int) -> Int? {
		guard line >= 1, line <= lineStartBytes.count else { return nil }
		let byte = lineStartBytes[line - 1] + (column - 1)
		let byteCount = byteToUTF16?.count ?? (processedUTF16.count + 1)
		guard byte >= 0, byte < byteCount else { return nil }
		return byteToUTF16?[byte] ?? byte
	}

	private func processedLineStart(_ line: Int) -> Int? {
		guard line >= 1, line <= lineStartBytes.count else { return nil }
		let byte = lineStartBytes[line - 1]
		return byteToUTF16?[byte] ?? byte
	}

	private func processedLineEnd(_ line: Int) -> Int? {
		guard line >= 1, line <= lineStartBytes.count else { return nil }
		if line < lineStartBytes.count {
			// Exclude the newline immediately before the next line.
			let byte = lineStartBytes[line]
			return max(0, (byteToUTF16?[byte] ?? byte) - 1)
		}
		return processedUTF16.count
	}

	private func mapToSource(_ processedOffset: Int) -> Int {
		guard let map else { return processedOffset }
		return processedOffset < map.count ? map[processedOffset] : (map.last ?? processedOffset)
	}
}
