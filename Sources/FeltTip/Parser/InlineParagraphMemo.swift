//
//  InlineParagraphMemo.swift
//  FeltTip
//
//  Every structural edit in the styled editor re-parses the whole document,
//  and building paragraph inline content is the largest share of that parse.
//  A paragraph's inline build depends only on its own source lines, the
//  theme, the font size, whether bare URLs are linkified, and the document's
//  link reference definitions — so an unchanged paragraph can reuse its
//  previous build. Source stamps are absolute offsets, so a reused build is
//  re-based by the paragraph's new position before use.
//
//  Used for display renders (no stamps, so nothing to shift) and for editable
//  renders whose preprocessing map is the identity: with a non-identity map a
//  stamp's value depends on the map around it and cannot be shifted uniformly.
//

import Foundation
import Markdown

final class InlineParagraphMemo: @unchecked Sendable {
	static let shared = InlineParagraphMemo()

	struct Key: Hashable {
		/// The paragraph's whole source lines, in processed-text UTF-16.
		let text: [UInt16]
		/// Where the built children sit inside `text`. A paragraph split around
		/// an inline image builds twice from the same lines with different
		/// children; without this the second build would reuse the first.
		let childRange: Range<Int>
		/// Theme signature, font size, linkify flag, and the document's link
		/// reference definitions — everything else the build reads.
		let context: String
		/// Resolved nodes also depend on block context outside a definition's
		/// blank-line-delimited chunk (for example, an enclosing code fence).
		let resolvedReferences: [ResolvedReference]
	}

	struct ResolvedReference: Hashable {
		let nodeIndex: Int
		let isImage: Bool
		let destination: String?
		let sourceRange: SourceRange?
	}

	static func resolvedReferences(in children: [Markup]) -> [ResolvedReference] {
		var result: [ResolvedReference] = []
		var nodeIndex = 0
		let firstLine = children.first?.range?.lowerBound.line ?? 1
		func relativeRange(_ node: Markup) -> SourceRange? {
			guard let range = node.range else { return nil }
			let lower = SourceLocation(line: range.lowerBound.line - firstLine + 1, column: range.lowerBound.column, source: nil)
			let upper = SourceLocation(line: range.upperBound.line - firstLine + 1, column: range.upperBound.column, source: nil)
			return lower..<upper
		}
		func visit(_ node: Markup) {
			let index = nodeIndex
			nodeIndex += 1
			if let link = node as? Markdown.Link {
				result.append(ResolvedReference(nodeIndex: index, isImage: false, destination: link.destination, sourceRange: relativeRange(node)))
			} else if let image = node as? Markdown.Image {
				result.append(ResolvedReference(nodeIndex: index, isImage: true, destination: image.source, sourceRange: relativeRange(node)))
			}
			for child in node.children { visit(child) }
		}
		for child in children { visit(child) }
		return result
	}

	struct Entry {
		let content: InlineContent
		let links: [LinkInfo]
		/// Absolute source offset of the first line the entry was built from.
		let sourceStart: Int
	}

	/// Key bytes retained before the cache is emptied. Entries hold the
	/// documents' paragraphs; a few open documents fit comfortably.
	static let capacityBytes = 24 << 20

	private let lock = NSLock()
	private var entries: [Key: Entry] = [:]
	private var keyBytes = 0

	/// Test hook: a disabled memo makes every lookup miss and stores nothing,
	/// which is the uncached build the parity tests compare against.
	nonisolated(unsafe) static var isEnabled = true

	func lookup(_ key: Key) -> Entry? {
		guard Self.isEnabled else { return nil }
		return lock.withLock { entries[key] }
	}

	func store(_ entry: Entry, for key: Key) {
		guard Self.isEnabled else { return }
		lock.withLock {
			if keyBytes > Self.capacityBytes {
				entries.removeAll(keepingCapacity: true)
				keyBytes = 0
			}
			if entries.updateValue(entry, forKey: key) == nil {
				keyBytes += key.text.count * 2
			}
		}
	}

	func removeAll() {
		lock.withLock {
			entries.removeAll()
			keyBytes = 0
		}
	}

	/// The build context for one document. Link reference definitions are the
	/// only part of a document outside a paragraph that changes how its
	/// inline content parses, so they are folded into the key.
	static func context(
		theme: MarkdownTheme, fontSize: CGFloat, linkifyURLs: Bool, stamped: Bool,
		processedText: String
	) -> String {
		"\(theme.signature)|\(fontSize)|\(linkifyURLs)|\(stamped)|\(definitionContext(in: processedText))"
	}

	/// Whether a `context` carries any definition chunk. Without one no
	/// reference can resolve, so the paragraph text alone determines its
	/// links and the resolved-reference walk can be skipped. A non-empty
	/// definition context always ends in a newline, never the separator.
	static func hasDefinitions(_ context: String) -> Bool {
		!context.hasSuffix("|")
	}

	/// Every run of non-blank lines that contains a `]:` line. cmark allows a
	/// definition to continue onto following lines, to sit inside a container
	/// (`> [id]: url`), and to be cancelled by a preceding paragraph line, so
	/// the whole blank-line-delimited chunk is keyed rather than one line.
	/// Resolved-reference nodes in the key additionally cover enclosing block
	/// context that can extend across blank lines.
	static func definitionContext(in processedText: String) -> String {
		guard DocumentScan.containsASCII("]:", in: processedText) else { return "" }
		var text = processedText
		return text.withUTF8 { bytes -> String in
			var output: [UInt8] = []
			var lineStart = 0
			var chunkStart = 0
			var chunkHasDefinition = false
			var chunkIsBlank = true
			var previousByte: UInt8 = 0
			var index = 0
			func flushChunk(upTo end: Int) {
				if chunkHasDefinition {
					let trimmedEnd = end > chunkStart && bytes[end - 1] == 0x0A ? end - 1 : end
					output.append(contentsOf: bytes[chunkStart..<trimmedEnd])
					output.append(0x0A)
				}
				chunkHasDefinition = false
				chunkIsBlank = true
			}
			while index <= bytes.count {
				let byte: UInt8 = index < bytes.count ? bytes[index] : 0x0A
				if byte == 0x0A {
					if chunkIsBlank {
						flushChunk(upTo: lineStart)
						chunkStart = index + 1
					}
					chunkIsBlank = true
					lineStart = index + 1
				} else {
					if byte != 0x20, byte != 0x09, byte != 0x0D { chunkIsBlank = false }
					if byte == 0x3A, previousByte == 0x5D { chunkHasDefinition = true }
				}
				previousByte = byte
				index += 1
			}
			flushChunk(upTo: bytes.count)
			return String(decoding: output, as: UTF8.self)
		}
	}

	/// `content` with every source stamp moved by `delta`.
	static func shiftingStamps(_ content: InlineContent, by delta: Int) -> InlineContent {
		content.shiftingStamps(by: delta)
	}
}
