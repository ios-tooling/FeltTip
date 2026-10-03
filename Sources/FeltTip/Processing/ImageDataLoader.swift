//
//  ImageDataLoader.swift
//  FeltTip
//

import Foundation

enum ImageDataLoader {
	static let maximumBytes = 64 * 1024 * 1024
	static let requestTimeout: TimeInterval = 30
	static let resourceTimeout: TimeInterval = 30

	/// A request timeout only limits a period without network progress. Pair it
	/// with a resource timeout so a server cannot hold image work open by
	/// trickling bytes indefinitely.
	static func sessionConfiguration() -> URLSessionConfiguration {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.timeoutIntervalForRequest = requestTimeout
		configuration.timeoutIntervalForResource = resourceTimeout
		return configuration
	}

	static func data(from url: URL) async throws -> Data {
		if url.isFileURL {
			return try localData(from: url)
		}

		guard url.scheme == "https" || url.scheme == "http" else {
			throw URLError(.unsupportedURL)
		}
		let request = URLRequest(url: url, timeoutInterval: requestTimeout)
		let session = URLSession(configuration: sessionConfiguration())
		defer { session.finishTasksAndInvalidate() }
		let (bytes, response) = try await session.bytes(for: request)
		if let http = response as? HTTPURLResponse,
		   !(200...299).contains(http.statusCode) {
			throw URLError(.badServerResponse)
		}
		if response.expectedContentLength > Int64(maximumBytes) {
			throw URLError(.dataLengthExceedsMaximum)
		}
		var data = Data()
		if response.expectedContentLength > 0 {
			data.reserveCapacity(min(Int(response.expectedContentLength), maximumBytes))
		}
		for try await byte in bytes {
			guard data.count < maximumBytes else {
				throw URLError(.dataLengthExceedsMaximum)
			}
			data.append(byte)
		}
		return data
	}

	static func localData(from url: URL) throws -> Data {
		let values = try url.resourceValues(forKeys: [.fileSizeKey])
		guard let size = values.fileSize, size <= maximumBytes else {
			throw URLError(.dataLengthExceedsMaximum)
		}
		let handle = try FileHandle(forReadingFrom: url)
		defer { try? handle.close() }
		let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
		guard data.count <= maximumBytes else {
			throw URLError(.dataLengthExceedsMaximum)
		}
		return data
	}
}
