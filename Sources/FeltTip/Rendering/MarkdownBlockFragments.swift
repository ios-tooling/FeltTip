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

	/// `html` with every `data-s` and `data-md-escaped-pipe-s` value moved by
	/// `delta`. Byte-level, like `rewritingStamps`.
	static func shiftingStamps(in html: String, by delta: Int) -> String {
		var html = html
		return html.withUTF8 { bytes in
			var output: [UInt8] = []
			output.reserveCapacity(bytes.count + 64)
			var cursor = 0
			var i = 0
			// Both attributes end in `-s="`; the bytes before decide which.
			let pipeTail = Array("data-md-escaped-pipe".utf8)
			while i + 4 <= bytes.count {
				if bytes[i] == 0x2D, bytes[i + 1] == 0x73, bytes[i + 2] == 0x3D, bytes[i + 3] == 0x22 {
					let isStamp = i >= 4 && bytes[i - 4] == 0x64 && bytes[i - 3] == 0x61
						&& bytes[i - 2] == 0x74 && bytes[i - 1] == 0x61
						&& (i == 4 || !isAttributeNameByte(bytes[i - 5]))
					let isPipe = i >= pipeTail.count
						&& bytes[(i - pipeTail.count)..<i].elementsEqual(pipeTail)
					if isStamp || isPipe, let stamp = stampValue(in: bytes, from: i + 4) {
						output.append(contentsOf: bytes[cursor..<(i + 4)])
						output.append(contentsOf: String(stamp.value + delta).utf8)
						cursor = stamp.end
						i = stamp.end
						continue
					}
				}
				i += 1
			}
			output.append(contentsOf: bytes[cursor...])
			return String(decoding: output, as: UTF8.self)
		}
	}

	private static func isAttributeNameByte(_ b: UInt8) -> Bool {
		(b >= 0x61 && b <= 0x7A) || (b >= 0x41 && b <= 0x5A) || (b >= 0x30 && b <= 0x39) || b == 0x2D || b == 0x5F
	}

	private static let stampAttribute = Array("data-s=\"".utf8)

	/// Index just past the next `data-s="` at or after `start`, or nil.
	private static func nextStampAttribute(
		in bytes: UnsafeBufferPointer<UInt8>, from start: Int
	) -> Int? {
		let needle = stampAttribute
		let limit = bytes.count - needle.count
		var i = start
		while i <= limit {
			if bytes[i] == 0x64, // 'd'
			   bytes[i + 1] == 0x61, bytes[i + 2] == 0x74, bytes[i + 3] == 0x61,
			   bytes[i + 4] == 0x2D, bytes[i + 5] == 0x73, bytes[i + 6] == 0x3D,
			   bytes[i + 7] == 0x22 {
				return i + needle.count
			}
			i += 1
		}
		return nil
	}

	/// Digits at `start` up to a closing quote: the stamp value and the index
	/// of that quote. Nil unless the attribute is exactly `"<digits>"`.
	private static func stampValue(
		in bytes: UnsafeBufferPointer<UInt8>, from start: Int
	) -> (value: Int, end: Int)? {
		var index = start
		var value = 0
		var sawDigit = false
		while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
			value = value &* 10 &+ Int(bytes[index] - 0x30)
			sawDigit = true
			index += 1
		}
		guard sawDigit, index < bytes.count, bytes[index] == 0x22 else { return nil }
		return (value, index)
	}

	/// The first stamp in `html`, found with a byte scan. The regex this
	/// replaced bridged every fragment to NSString and ran ICU per block on
	/// every render.
	static func firstStamp(in html: String) -> Int? {
		var html = html
		return html.withUTF8 { bytes in
			var searchStart = 0
			while let valueStart = nextStampAttribute(in: bytes, from: searchStart) {
				if let stamp = stampValue(in: bytes, from: valueStart) { return stamp.value }
				searchStart = valueStart
			}
			return nil
		}
	}

	/// `html` with every `data-s` value rewritten relative to `base`. Works on
	/// bytes and splices ASCII digits, so the result decodes as valid UTF-8.
	static func rewritingStamps(in html: String, base: Int) -> String {
		var html = html
		return html.withUTF8 { bytes in
			var output: [UInt8] = []
			output.reserveCapacity(bytes.count)
			var cursor = 0
			var searchStart = 0
			while let valueStart = nextStampAttribute(in: bytes, from: searchStart) {
				searchStart = valueStart
				guard let stamp = stampValue(in: bytes, from: valueStart) else { continue }
				output.append(contentsOf: bytes[cursor..<valueStart])
				output.append(contentsOf: String(stamp.value - base).utf8)
				cursor = stamp.end
				searchStart = stamp.end
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
