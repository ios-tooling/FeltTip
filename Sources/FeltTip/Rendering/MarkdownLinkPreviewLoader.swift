//
//  MarkdownLinkPreviewLoader.swift
//  FeltTip
//

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
	private static let readTimeout: Duration = .seconds(10)

	static func load(
		requestURL: URL,
		accessPolicy: LocalResourceAccessPolicy,
		timeout: Duration = readTimeout,
		reader: @escaping @Sendable (URL) -> MarkdownLinkPreview? = read
	) async -> MarkdownLinkPreview? {
		return try? await BoundedSynchronousWork.run(timeout: timeout) {
			guard let fileURL = accessPolicy.authorizedMarkdownURL(for: requestURL) else { return nil }
			return reader(fileURL)
		}
	}

	private static func read(_ fileURL: URL) -> MarkdownLinkPreview? {
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
}
