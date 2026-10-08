import Foundation
import Markdown

/// Keep the parser's code regions opaque to the extension preprocessors.
/// A single shared boundary handles long/tilde fences, nested and indented
/// blocks, and multi-backtick or multiline inline spans consistently.
enum MarkdownCodeProtection {
	@TaskLocal private static var isProtecting = false
	@TaskLocal private static var blockMarkerPrefix: String?

	static func containsProtectedBlock(_ line: String) -> Bool {
		guard let blockMarkerPrefix else { return false }
		return line.contains(blockMarkerPrefix)
	}

	private struct Region {
		let range: NSRange
		let isBlock: Bool
	}
	static func ranges(in source: String, blocksOnly: Bool = false) -> [NSRange] {
		regions(in: source, blocksOnly: blocksOnly).map(\.range)
	}

	private static func regions(in source: String, blocksOnly: Bool = false) -> [Region] {
		guard mayContainCode(source) else { return [] }
		let converter = SourceOffsetConverter(source)
		var ranges: [Region] = []
		func walk(_ node: any Markup) {
			guard !Task.isCancelled else { return }
			if node is CodeBlock || (!blocksOnly && node is InlineCode) {
				if let range = node.range,
				   let offsets = converter.processedRange(
					lowerLine: range.lowerBound.line, lowerColumn: range.lowerBound.column,
					upperLine: range.upperBound.line, upperColumn: range.upperBound.column) {
					ranges.append(Region(range: NSRange(location: offsets.lowerBound, length: offsets.count), isBlock: node is CodeBlock))
				}
				return
			}
			for child in node.children { walk(child) }
		}
		walk(Document(parsing: source, options: .disableSmartOpts))
		return ranges
	}

	private static func mayContainCode(_ source: String) -> Bool {
		var source = source
		return source.withUTF8 { bytes in
			var spaces = 0
			var tildes = 0
			for byte in bytes {
				if byte == 0x60 || byte == 0x09 { return true }
				spaces = byte == 0x20 ? spaces + 1 : 0
				tildes = byte == 0x7E ? tildes + 1 : 0
				if spaces == 4 || tildes == 3 { return true }
			}
			return false
		}
	}

	static func transform(_ source: String, using transform: (String) -> String?) -> String? {
		map(source) { masked, restore in transform(masked).map(restore) }
	}

	static func map<T>(_ source: String, using transform: (String, (String) -> String) -> T) -> T {
		guard !isProtecting else { return transform(source, { $0 }) }
		let ranges = regions(in: source)
		guard !ranges.isEmpty else { return $isProtecting.withValue(true) { transform(source, { $0 }) } }
		var prefix: String
		repeat { prefix = "FELTTIPCODE" + UUID().uuidString.replacingOccurrences(of: "-", with: "") } while source.contains(prefix)
		let ns = source as NSString
		var originals: [String] = []
		var masked = ""
		var cursor = 0
		for region in ranges {
			let range = region.range
			masked += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
			// One token per line preserves block/container boundaries. Restoring
			// a token never introduces new lines into a transformed quote/list.
			let lines = ns.substring(with: range).components(separatedBy: "\n")
			for (index, line) in lines.enumerated() {
				if index > 0 { masked += "\n" }
				if !line.isEmpty {
					masked += prefix + (region.isBlock ? "BLOCK" : "INLINE") + String(originals.count) + "END"
					originals.append(line)
				}
			}
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
			$blockMarkerPrefix.withValue(prefix + "BLOCK") { transform(masked, restore) }
		}
	}
}
