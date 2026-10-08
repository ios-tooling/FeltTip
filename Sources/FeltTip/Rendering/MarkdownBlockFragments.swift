//
//  MarkdownBlockFragments.swift
//  FeltTip
//
//  Per-block render output for incremental page updates. A fragment's
//  `signature` is its HTML with every data-s stamp rewritten relative to the
//  fragment's first stamp — stable across pure source-offset shifts, so an
//  edit early in the document doesn't make every later block look changed.
//

import Foundation

public struct MarkdownBlockFragment: Sendable, Equatable {
	public let html: String
	/// Offset-relative HTML used only when the block diff examines this
	/// fragment as part of a potentially unchanged suffix. Keeping it lazy
	/// avoids duplicating and regex-rewriting every block's HTML during the
	/// initial render and for unchanged prefixes on later renders.
	public var signature: String { signatureCache.value(html: html, base: firstStamp) }
	/// The fragment's first absolute data-s stamp; nil for unstamped blocks.
	public let firstStamp: Int?
	/// `MarkdownBlock.contentHash` of the block this HTML was rendered from,
	/// so a later render can reuse the fragment for an unchanged block. Its
	/// `stampBase` is the absolute stamp the hash is relative to; a later
	/// block with the same hash at another base takes this HTML with every
	/// stamp shifted by the difference.
	let blockHash: MarkdownBlockContentHash?
	private let signatureCache = SignatureCache()

	/// `mayContainStamps` is false for renders without source offsets, where
	/// no fragment can carry a stamp and the scan would be wasted per block.
	init(html: String, mayContainStamps: Bool = true, blockHash: MarkdownBlockContentHash? = nil) {
		self.html = html
		firstStamp = mayContainStamps ? Self.firstStamp(in: html) : nil
		self.blockHash = blockHash
	}

	/// This fragment re-rendered for the same block content at a new stamp
	/// base: the HTML with every `data-s` and escaped-pipe stamp shifted.
	func rebased(to hash: MarkdownBlockContentHash) -> MarkdownBlockFragment {
		guard let blockHash, let oldBase = blockHash.stampBase, let newBase = hash.stampBase,
		      oldBase != newBase else {
			return MarkdownBlockFragment(html: html, mayContainStamps: firstStamp != nil, blockHash: hash)
		}
		return MarkdownBlockFragment(
			html: Self.shiftingStamps(in: html, by: newBase - oldBase),
			mayContainStamps: true, blockHash: hash)
	}

	private static let escapedPipeAttribute = Array("data-md-escaped-pipe-s=\"".utf8)

	/// Only actual tag attributes are stamps: text, comments, and attribute
	/// values can also contain the literal spelling `data-s="..."`.
	private static func stamps(in bytes: UnsafeBufferPointer<UInt8>, firstOnly: Bool = false) -> [(value: Int, start: Int, end: Int, pipe: Bool)] {
		var result: [(value: Int, start: Int, end: Int, pipe: Bool)] = []
		var inTag = false
		var quote: UInt8?
		var i = 0
		while i < bytes.count {
			let byte = bytes[i]
			if let delimiter = quote {
				if byte == delimiter { quote = nil }
			} else if !inTag {
				if byte == 0x3C {
					if i + 4 <= bytes.count, bytes[i..<(i + 4)].elementsEqual("<!--".utf8) {
						i += 4
						if i < bytes.count, bytes[i] == 0x3E { i += 1; continue }
						if i + 1 < bytes.count, bytes[i] == 0x2D, bytes[i + 1] == 0x3E { i += 2; continue }
						while i < bytes.count {
							if i + 3 <= bytes.count, bytes[i..<(i + 3)].elementsEqual("-->".utf8) { i += 3; break }
							if i + 4 <= bytes.count, bytes[i..<(i + 4)].elementsEqual("--!>".utf8) { i += 4; break }
							i += 1
						}
						continue
					}
					inTag = true
				}
			} else if byte == 0x3E {
				inTag = false
			} else if byte == 0x22 || byte == 0x27 {
				// Only a value's opening quote starts quoted state: an
				// apostrophe in an unquoted value (`title=it's`) must not
				// swallow the rest of the fragment.
				var previous = i - 1
				while previous >= 0, bytes[previous] == 0x20 || bytes[previous] == 0x09
					|| bytes[previous] == 0x0A || bytes[previous] == 0x0D { previous -= 1 }
				if previous >= 0, bytes[previous] == 0x3D { quote = byte }
			} else if byte == 0x64, i > 0 {
				let previous = bytes[i - 1]
				if previous == 32 || previous == 9 || previous == 10 || previous == 12 || previous == 13 {
					let ordinary = i + 8 <= bytes.count
						&& bytes[i + 1] == 0x61 && bytes[i + 2] == 0x74 && bytes[i + 3] == 0x61
						&& bytes[i + 4] == 0x2D && bytes[i + 5] == 0x73 && bytes[i + 6] == 0x3D && bytes[i + 7] == 0x22
					let pipe = !ordinary && i + escapedPipeAttribute.count <= bytes.count
						&& bytes[i..<(i + escapedPipeAttribute.count)].elementsEqual(escapedPipeAttribute)
					if ordinary || pipe {
						let start = i + (ordinary ? 8 : escapedPipeAttribute.count)
						if let stamp = stampValue(in: bytes, from: start) {
							result.append((stamp.value, start, stamp.end, pipe))
							if firstOnly && !pipe { return result }
							// The validated number ends at its closing quote. Skip the
							// whole attribute so it isn't scanned again byte by byte.
							i = stamp.end
						}
					}
				}
			}
			i += 1
		}
		return result
	}

	private static func stampValue(
		in bytes: UnsafeBufferPointer<UInt8>, from start: Int
	) -> (value: Int, end: Int)? {
		var index = start
		var value = 0
		while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
			let (scaled, multiplyOverflow) = value.multipliedReportingOverflow(by: 10)
			let (next, addOverflow) = scaled.addingReportingOverflow(Int(bytes[index] - 0x30))
			guard !multiplyOverflow, !addOverflow else { return nil }
			value = next
			index += 1
		}
		guard index > start, index < bytes.count, bytes[index] == 0x22 else { return nil }
		return (value, index)
	}

	static func firstStamp(in html: String) -> Int? {
		var html = html
		return html.withUTF8 { bytes in stamps(in: bytes, firstOnly: true).first(where: { !$0.pipe })?.value }
	}

	static func shiftingStamps(in html: String, by delta: Int) -> String {
		transformStamps(in: html, includingPipes: true) { value in
			let (shifted, overflow) = value.addingReportingOverflow(delta)
			return overflow ? nil : shifted
		}
	}

	static func rewritingStamps(in html: String, base: Int) -> String {
		transformStamps(in: html, includingPipes: false) { value in
			let (relative, overflow) = value.subtractingReportingOverflow(base)
			return overflow ? nil : relative
		}
	}

	private static func transformStamps(
		in html: String, includingPipes: Bool, transform: (Int) -> Int?
	) -> String {
		var html = html
		return html.withUTF8 { bytes in
			var output: [UInt8] = []
			output.reserveCapacity(bytes.count + 64)
			var cursor = 0
			for stamp in stamps(in: bytes) where includingPipes || !stamp.pipe {
				guard let value = transform(stamp.value) else { continue }
				output.append(contentsOf: bytes[cursor..<stamp.start])
				output.append(contentsOf: String(value).utf8)
				cursor = stamp.end
			}
			output.append(contentsOf: bytes[cursor...])
			return String(decoding: output, as: UTF8.self)
		}
	}

	/// Test-visible evidence that no signature allocation happened yet.
	var hasCachedSignature: Bool { signatureCache.hasValue }

	public static func == (lhs: Self, rhs: Self) -> Bool {
		// firstStamp and signature are derived entirely from HTML.
		lhs.html == rhs.html
	}

	private final class SignatureCache: @unchecked Sendable {
		private let lock = NSLock()
		private var cached: String?

		var hasValue: Bool {
			lock.withLock { cached != nil }
		}

		func value(html: String, base: Int?) -> String {
			lock.withLock {
				if let cached { return cached }
				guard let base else {
					cached = html
					return html
				}
				let rewritten = MarkdownBlockFragment.rewritingStamps(in: html, base: base)
				cached = rewritten
				return rewritten
			}
		}
	}
}

extension MarkdownHTMLRenderer {
	/// The body fragment as one rendered string per block, under the same
	/// per-render flags as `renderBodyFragment` (whose output is exactly these
	/// fragments joined).
	public static func renderBlockFragments(
		markdown: String,
		theme: MarkdownTheme = .default,
		fontSize: CGFloat = 16,
		options: MarkdownOptions = .default,
		includeSourceOffsets: Bool = false,
		interactiveCheckboxes: Bool = false,
		baseline: [MarkdownBlockFragment]? = nil
	) -> [MarkdownBlockFragment] {
		let blocks = includeSourceOffsets
			? MarkdownBlockParser.parse(markdown, theme: theme, fontSize: fontSize, trackSourceOffsets: true, options: options)
			: MarkdownBlockParser.parse(markdown, theme: theme, fontSize: fontSize, options: options)
		// A block's HTML depends only on its content and these two flags, so a
		// block whose content hash matches a baseline fragment rendered under
		// the same flags can take that fragment as is. Stamps and checkbox
		// indices are part of the content, so anything an edit shifted misses.
		let flags = (includeSourceOffsets ? 1 : 0) | (interactiveCheckboxes ? 2 : 0)
		// Keyed by the stamp-relative hash value alone: a block that only moved
		// matches a baseline fragment at another base and takes its HTML with
		// the stamps shifted.
		var reusable: [Int: MarkdownBlockFragment] = [:]
		if let baseline {
			reusable.reserveCapacity(baseline.count)
			for fragment in baseline {
				if let hash = fragment.blockHash, reusable[hash.value] == nil { reusable[hash.value] = fragment }
			}
		}
		return $emitSourceOffsets.withValue(includeSourceOffsets) {
			$emitInteractiveCheckboxes.withValue(interactiveCheckboxes) {
				var fragments: [MarkdownBlockFragment] = []
				fragments.reserveCapacity(blocks.count)
				for block in blocks {
					if Task.isCancelled { break }
					let hash = block.contentHash(flags: flags)
					if let previous = reusable[hash.value] {
						fragments.append(previous.blockHash == hash ? previous : previous.rebased(to: hash))
						continue
					}
					fragments.append(MarkdownBlockFragment(
						html: renderBlock(block), mayContainStamps: includeSourceOffsets,
						blockHash: hash))
				}
				return fragments
			}
		}
	}
}
