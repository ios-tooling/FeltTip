//
//  ImageDataLoader.swift
//  MarkDownRange
//

import Foundation

enum ImageDataLoader {
	static func data(from url: URL) async throws -> Data {
		if url.isFileURL {
			return try Data(contentsOf: url)
		}

		let (data, _) = try await URLSession.shared.data(from: url)
		return data
	}
}
