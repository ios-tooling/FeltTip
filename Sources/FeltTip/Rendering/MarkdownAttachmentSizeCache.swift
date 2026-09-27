//
//  MarkdownAttachmentSizeCache.swift
//  FeltTip
//
//  Process-lifetime cache for attachment heights, keyed by structural
//  fingerprint (line count for code blocks, row × col count for tables,
//  etc.). Two attachments with the same structural fingerprint and the
//  same measurement width measure to the same height, so we only need to
//  pay NSHostingController.sizeThatFits once per *kind* of block. On a
//  200-section document with 200 code blocks + 200 tables + repeating
//  shape, this collapses 400 measurements down to 2.
//

import Foundation

public struct MarkdownAttachmentSizeKey: Hashable, Sendable {
	let kind: String
	let fontSize: CGFloat
	let width: CGFloat
}

@MainActor
public final class MarkdownAttachmentSizeCache {
	public static let shared = MarkdownAttachmentSizeCache()
	private var storage: [MarkdownAttachmentSizeKey: CGFloat] = [:]

	public subscript(key: MarkdownAttachmentSizeKey) -> CGFloat? {
		get { storage[key] }
		set { storage[key] = newValue }
	}

	/// Empties the cache. Exposed mainly so benchmarks can measure cold
	/// (cache-miss) rendering; not used in normal operation.
	public func removeAll() {
		storage.removeAll()
	}

	/// Returns a key when the block has a deterministic structural shape we
	/// can reuse a measurement for. Returns nil for blocks whose rendered
	/// height genuinely depends on the unique content (HTML, deeply nested
	/// children) — those still go through NSHostingController.sizeThatFits.
	public static func key(for block: MarkdownBlock, fontSize: CGFloat, width: CGFloat) -> MarkdownAttachmentSizeKey? {
		guard let kind = structuralKind(for: block) else { return nil }
		return MarkdownAttachmentSizeKey(kind: kind, fontSize: fontSize, width: width)
	}

	private static func structuralKind(for block: MarkdownBlock) -> String? {
		switch block {
		case .codeBlock(let code, let lang, _, _):
			let lineCount = code.split(separator: "\n", omittingEmptySubsequences: false).count
			// Hash the content, not just the shape: two blocks with the same line
			// count can still wrap to different heights, so keying on shape alone
			// lets a taller block reuse a shorter one's cached height and clip.
			return "code|\(lang ?? "")|\(lineCount)|\(code.hashValue)"
		case .table(let header, let rows, _, _):
			// Same reasoning as code blocks: tables with the same row/column count
			// can wrap to different heights depending on their cell text.
			return "table|cols=\(header.count)|rows=\(rows.count)|\(tableContentHash(header, rows))"
		case .frontmatter(let pairs, _):
			return "frontmatter|count=\(pairs.count)"
		case .image, .imageRow, .figure, .htmlBlock, .details, .alert:
			// Heights for these depend on content (image dimensions, html
			// shape, nested children) so don't share keys across instances.
			return nil
		default:
			return nil
		}
	}

	/// Per-process content fingerprint of a table's cells, so two tables of the
	/// same shape but different text don't share a cached height.
	private static func tableContentHash(_ header: [TableCell], _ rows: [[TableCell]]) -> Int {
		var hasher = Hasher()
		func combine(_ cell: TableCell) {
			switch cell {
			case .text(let str, _): hasher.combine(String(str.characters))
			case .image(let source, _, _, _, _): hasher.combine(source)
			}
		}
		header.forEach(combine)
		for row in rows { row.forEach(combine) }
		return hasher.finalize()
	}
}
