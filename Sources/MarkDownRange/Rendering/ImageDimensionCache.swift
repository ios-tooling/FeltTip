//
//  ImageDimensionCache.swift
//  MarkDownRange
//
//  Process-wide cache of remote image dimensions, used by the native
//  renderer to size image attachments correctly on the first layout
//  pass instead of measuring the placeholder and clipping the real
//  image once it loads.
//

import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

final class ImageDimensionCache: @unchecked Sendable {
	static let shared = ImageDimensionCache()

	private let lock = NSLock()
	private var sizes: [URL: CGSize] = [:]
	private var inFlight: Set<URL> = []
	private var subscribers: [UUID: @Sendable () -> Void] = [:]

	func size(for url: URL) -> CGSize? {
		lock.lock(); defer { lock.unlock() }
		return sizes[url]
	}

	func record(_ size: CGSize, for url: URL) {
		guard size.width > 0, size.height > 0 else { return }
		lock.lock()
		let changed = sizes[url] != size
		sizes[url] = size
		let callbacks = changed ? Array(subscribers.values) : []
		lock.unlock()
		guard !callbacks.isEmpty else { return }
		DispatchQueue.main.async { callbacks.forEach { $0() } }
	}

	func subscribe(_ callback: @escaping @Sendable () -> Void) -> UUID {
		let token = UUID()
		lock.lock()
		subscribers[token] = callback
		lock.unlock()
		return token
	}

	func unsubscribe(_ token: UUID) {
		lock.lock()
		subscribers.removeValue(forKey: token)
		lock.unlock()
	}

	func prefetch(_ url: URL) {
		guard claimInFlight(url) else { return }
		Task {
			let size = await Self.fetchSize(url)
			self.releaseInFlight(url)
			if let size { self.record(size, for: url) }
		}
	}

	/// Load dimensions synchronously for file URLs so the first measurement
	/// pass — particularly the one in QuickLook where async loads may not
	/// finish before the preview is dismissed — already has the real size.
	/// No-op for non-file URLs and for URLs that are already cached.
	func prefetchSyncIfLocal(_ url: URL) {
		guard url.isFileURL else { return }
		if size(for: url) != nil { return }
		guard let data = try? Data(contentsOf: url) else { return }
		let measured: CGSize?
		if url.isSVGImage {
			let text = String(data: data, encoding: .utf8) ?? ""
			measured = SVGDimensionParser.parse(text)
		} else {
			#if os(macOS)
			measured = NSImage(data: data)?.size
			#else
			measured = UIImage(data: data)?.size
			#endif
		}
		guard let measured, measured.width > 0, measured.height > 0 else { return }
		record(measured, for: url)
	}

	private func claimInFlight(_ url: URL) -> Bool {
		lock.lock(); defer { lock.unlock() }
		if sizes[url] != nil || inFlight.contains(url) { return false }
		inFlight.insert(url)
		return true
	}

	private func releaseInFlight(_ url: URL) {
		lock.lock(); defer { lock.unlock() }
		inFlight.remove(url)
	}

	private static func fetchSize(_ url: URL) async -> CGSize? {
		guard let data = try? await ImageDataLoader.data(from: url) else { return nil }
		if url.isSVGImage {
			let text = String(data: data, encoding: .utf8) ?? ""
			return SVGDimensionParser.parse(text)
		}
		#if os(macOS)
		guard let img = NSImage(data: data), img.size.width > 0 else { return nil }
		return img.size
		#else
		guard let img = UIImage(data: data), img.size.width > 0 else { return nil }
		return img.size
		#endif
	}
}
