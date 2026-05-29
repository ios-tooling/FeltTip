//
//  MarkdownAttachmentSizeCache.swift
//  MarkDownRange
//
//  Process-lifetime cache for attachment heights, keyed by structural
//  fingerprint (line count for code blocks, row × col count for tables,
//  etc.). Two attachments with the same structural fingerprint and the
//  same measurement width measure to the same height, so we only need to
//  pay NSHostingController.sizeThatFits once per *kind* of block. On a
//  200-section document with 200 code blocks + 200 tables + repeating
//  shape, this collapses 400 measurements down to 2.
//

#if os(macOS)
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
		case .codeBlock(let code, let lang, _):
			let lineCount = code.split(separator: "\n", omittingEmptySubsequences: false).count
			return "code|\(lang ?? "")|\(lineCount)"
		case .table(let header, let rows, _, _):
			return "table|cols=\(header.count)|rows=\(rows.count)"
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
}
#endif
