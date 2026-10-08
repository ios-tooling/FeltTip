import Foundation
import Markdown

/// Keep the parser's code regions opaque to the extension preprocessors.
/// A single shared boundary handles long/tilde fences, nested and indented
/// blocks, and multi-backtick or multiline inline spans consistently.
enum MarkdownCodeProtection {
	@TaskLocal private static var isProtecting = false
	@TaskLocal private static var blockMarkerPrefix: String?
	@TaskLocal private static var inlineMarkerPrefix: String?

	static func containsProtectedBlock(_ line: String) -> Bool {
		guard let blockMarkerPrefix else { return false }
		return line.contains(blockMarkerPrefix)
	}

	/// The end of a masked inline code span starting at `index`, when one
	/// does. Processors that pair markers across plain text treat the token
	/// as the opaque code span it stands for, so `~a `x` b~` never pairs
	/// across the span.
	static func protectedInlineToken(in line: String, at index: String.Index) -> String.Index? {
		guard let inlineMarkerPrefix, line[index...].hasPrefix(inlineMarkerPrefix),
		      let end = line.range(of: "END", range: index..<line.endIndex) else { return nil }
		return end.upperBound
	}

	private struct Region {
		let range: NSRange
		let isBlock: Bool
		/// Backtick run length of an inline span; zero for blocks.
		let delimiterLength: Int
	}
	static func ranges(in source: String, blocksOnly: Bool = false) -> [NSRange] {
		regions(in: source, blocksOnly: blocksOnly).map(\.range)
	}

	private static func regions(in source: String, blocksOnly: Bool = false) -> [Region] {
		guard mayContainCode(source) else { return [] }
		let converter = SourceOffsetConverter(source)
		var regions: [Region] = []
		// swift-markdown can report inline nodes on lazy list-continuation
		// lines at the list content's virtual indentation, so a reported
		// range may be shifted into a later block. Regions must stay in
		// document order and disjoint; anything else is left unprotected.
		func append(_ region: Region) {
			let previousEnd = regions.last.map { NSMaxRange($0.range) } ?? 0
			guard region.range.location >= previousEnd,
			      NSMaxRange(region.range) <= converter.processedUTF16Count else { return }
			regions.append(region)
		}
		func walk(_ node: any Markup) {
			guard !Task.isCancelled else { return }
			if node is CodeBlock {
				if let range = node.range,
				   let offsets = converter.processedRange(
					lowerLine: range.lowerBound.line, lowerColumn: range.lowerBound.column,
					upperLine: range.upperBound.line, upperColumn: range.upperBound.column) {
					append(Region(range: NSRange(location: offsets.lowerBound, length: offsets.count), isBlock: true, delimiterLength: 0))
				}
				return
			}
			if blocksOnly {
				// Code blocks only live in block containers; skip inline trees.
				guard node is BlockContainer else { return }
			} else if let inline = node as? InlineCode {
				if let region = inlineRegion(inline, converter: converter) { append(region) }
				return
			}
			for child in node.children { walk(child) }
		}
		walk(Document(parsing: source, options: .disableSmartOpts))
		return regions
	}

	/// The validated span of an inline code node: its reported range when
	/// that really is backtick-delimited text, otherwise the unique span on
	/// the node's source lines whose content is the node's code.
	private static func inlineRegion(_ node: InlineCode, converter: SourceOffsetConverter) -> Region? {
		guard let range = node.range else { return nil }
		if let offsets = converter.processedRange(
			lowerLine: range.lowerBound.line, lowerColumn: range.lowerBound.column,
			upperLine: range.upperBound.line, upperColumn: range.upperBound.column),
		   let length = delimiterLength(of: converter.processedSlice(offsets)) {
			return Region(range: NSRange(location: offsets.lowerBound, length: offsets.count), isBlock: false, delimiterLength: length)
		}
		guard let span = converter.lineSpan(lowerLine: range.lowerBound.line, upperLine: range.upperBound.line) else { return nil }
		let text = Array(converter.processedSlice(span.range))
		// cmark folds a span's line endings into spaces and strips one
		// symmetric padding space.
		let code = Array(node.code.utf16)
		var found: Range<Int>?
		var index = 0
		while index < text.count {
			guard text[index] == 0x60 else { index += 1; continue }
			let start = index
			while index < text.count, text[index] == 0x60 { index += 1 }
			let length = index - start
			var closeStart: Int?
			var scan = index
			while scan < text.count {
				guard text[scan] == 0x60 else { scan += 1; continue }
				let runStart = scan
				while scan < text.count, text[scan] == 0x60 { scan += 1 }
				if scan - runStart == length { closeStart = runStart; break }
			}
			guard let closeStart else { continue }
			// A continuation line's indentation is block structure, not span
			// content, and each line ending becomes one space.
			var content: [UInt16] = []
			var atLineBreak = false
			for unit in text[index..<closeStart] {
				if unit == 0x0A || unit == 0x0D {
					if !atLineBreak { content.append(0x20) }
					atLineBreak = true
				} else if atLineBreak, unit == 0x20 || unit == 0x09 {
					continue
				} else {
					atLineBreak = false
					content.append(unit)
				}
			}
			if content.count >= 2, content.first == 0x20, content.last == 0x20,
			   content.contains(where: { $0 != 0x20 }) {
				content.removeFirst(); content.removeLast()
			}
			if content == code {
				if found != nil { return nil }
				found = start..<(closeStart + length)
			}
			index = closeStart + length
		}
		return found.map {
			Region(range: NSRange(location: span.range.lowerBound + $0.lowerBound, length: $0.count),
			       isBlock: false, delimiterLength: text[$0].prefix { $0 == 0x60 }.count)
		}
	}

	private static func delimiterLength(of slice: ArraySlice<UInt16>) -> Int? {
		let length = slice.prefix { $0 == 0x60 }.count
		guard length > 0, slice.count >= length * 2,
		      slice.suffix(length).allSatisfy({ $0 == 0x60 }),
		      slice.count == length * 2 || slice[slice.endIndex - length - 1] != 0x60 else { return nil }
		return length
	}

	/// A cheap rejection for documents that cannot contain code: no backtick,
	/// tab, or tilde fence, and no line starting with four spaces (indented
	/// code can follow any block boundary, so the line before is no guide).
	private static func mayContainCode(_ source: String) -> Bool {
		var source = source
		return source.withUTF8 { bytes in
			var spaces = 0
			var tildes = 0
			var lineStart = true
			for byte in bytes {
				if byte == 0x60 || byte == 0x09 { return true }
				if byte == 0x0A {
					lineStart = true
					spaces = 0
					tildes = 0
					continue
				}
				if lineStart, byte == 0x20 {
					spaces += 1
					if spaces == 4 { return true }
				} else {
					lineStart = false
				}
				tildes = byte == 0x7E ? tildes + 1 : 0
				if tildes == 3 { return true }
			}
			return false
		}
	}

	static func transform(_ source: String, using transform: (String) -> String?) -> String? {
		map(source) { masked, restore in transform(masked).map(restore) }
	}

	static func map<T>(_ source: String, using transform: (String, (String) -> String) -> T) -> T {
		guard !isProtecting else { return transform(source, { $0 }) }
		let regions = regions(in: source)
		guard !regions.isEmpty else { return $isProtecting.withValue(true) { transform(source, { $0 }) } }
		var prefix: String
		repeat { prefix = "FELTTIPCODE" + UUID().uuidString.replacingOccurrences(of: "-", with: "") } while source.contains(prefix)
		let ns = source as NSString
		var originals: [String] = []
		var masked = ""
		var cursor = 0
		// One token per line preserves block/container boundaries. Restoring
		// a token never introduces new lines into a transformed quote/list.
		func appendTokens(for text: String, isBlock: Bool) {
			for (index, line) in text.components(separatedBy: "\n").enumerated() {
				if index > 0 { masked += "\n" }
				if !line.isEmpty {
					masked += prefix + (isBlock ? "BLOCK" : "INLINE") + String(originals.count) + "END"
					originals.append(line)
				}
			}
		}
		for region in regions {
			let range = region.range
			masked += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
			appendTokens(for: ns.substring(with: range), isBlock: region.isBlock)
			cursor = NSMaxRange(range)
		}
		masked += ns.substring(from: cursor)
		func restore(_ processed: String) -> String {
			var restored = ""
			var start = processed.startIndex
			while let marker = processed.range(of: prefix, range: start..<processed.endIndex) {
				restored += processed[start..<marker.lowerBound]
				guard let end = processed.range(of: "END", range: marker.upperBound..<processed.endIndex),
				      let index = Int(processed[marker.upperBound..<end.lowerBound].dropFirst(processed[marker.upperBound...].hasPrefix("BLOCK") ? 5 : 6)),
				      originals.indices.contains(index) else {
					restored += prefix
					start = marker.upperBound
					continue
				}
				restored += originals[index]
				start = end.upperBound
			}
			restored += processed[start...]
			return restored
		}
		return $isProtecting.withValue(true) {
			$blockMarkerPrefix.withValue(prefix + "BLOCK") {
				$inlineMarkerPrefix.withValue(prefix + "INLINE") { transform(masked, restore) }
			}
		}
	}
}
