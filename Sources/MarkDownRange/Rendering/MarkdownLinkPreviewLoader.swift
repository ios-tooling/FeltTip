//
//  MarkdownLinkPreviewLoader.swift
//  MarkDownRange
//

#if os(macOS)
import Foundation

struct MarkdownLinkPreview: Sendable, Equatable {
	struct Pair: Sendable, Equatable {
		let key: String
		let value: String
	}

	let filename: String
	let pairs: [Pair]
}

/// Reads just enough of an authorized local Markdown target to extract its
/// opening frontmatter. Link hovers must never turn into unbounded main-thread
/// filesystem work, especially for generated or accidentally huge documents.
enum MarkdownLinkPreviewLoader {
	private static let maximumBytes = 256 * 1024

	static func load(
		requestURL: URL,
		accessPolicy: LocalResourceAccessPolicy
	) async -> MarkdownLinkPreview? {
		guard let fileURL = accessPolicy.authorizedMarkdownURL(for: requestURL) else { return nil }
		return await Task.detached(priority: .userInitiated) {
			guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
			defer { try? handle.close() }
			guard let data = try? handle.read(upToCount: maximumBytes) else { return nil }
			let source = String(decoding: data, as: UTF8.self)
			guard case .frontmatter(let pairs, _)? = MarkdownBlockParser.parse(source).first
			else { return nil }
			return MarkdownLinkPreview(
				filename: fileURL.lastPathComponent,
				pairs: pairs.map { .init(key: $0.key, value: $0.value) })
		}
		.value
	}
}
#endif
