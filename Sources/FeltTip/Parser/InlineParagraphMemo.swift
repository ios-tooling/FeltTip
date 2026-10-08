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
	}

	struct Entry {
		let attributed: AttributedString
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
	/// inline content parses. Return nil when references may be present.
	static func context(
		theme: MarkdownTheme, fontSize: CGFloat, linkifyURLs: Bool, stamped: Bool,
		processedText: String
	) -> String? {
		// cmark permits multiline definitions and definitions inside containers.
		// Until its resolved reference table is available here, bypass memoization
		// for potential definition documents rather than approximate that grammar.
		guard !DocumentScan.containsASCII("]:", in: processedText) else { return nil }
		return "\(theme.signature)|\(fontSize)|\(linkifyURLs)|\(stamped)"
	}

	/// `attributed` with every source stamp moved by `delta`.
	static func shiftingStamps(_ attributed: AttributedString, by delta: Int) -> AttributedString {
		guard delta != 0 else { return attributed }
		var result = attributed
		for run in attributed.runs {
			if let offset = run.markdownSourceOffset {
				result[run.range].markdownSourceOffset = offset + delta
			}
			if let pipe = run.markdownEscapedPipeSourceOffset {
				result[run.range].markdownEscapedPipeSourceOffset = pipe + delta
			}
		}
		return result
	}
}
