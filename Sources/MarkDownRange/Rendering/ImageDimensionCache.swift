//
//  ImageDimensionCache.swift
//  MarkDownRange
//
//  Process-wide cache of image dimensions, used by the native renderer to
//  size image attachments correctly on the first layout pass instead of
//  measuring the placeholder and clipping the real image once it loads.
//  Sizes also persist between launches via JohnnyCache so a re-opened
//  document doesn't replay the "placeholder → real size" reflow flash for
//  images we've already measured.
//

import Foundation
import JohnnyCache
#if os(macOS)
import AppKit
#else
import UIKit
#endif

private struct ImageDimensionRecord: Codable, Sendable, CacheableElement {
	let width: CGFloat
	let height: CGFloat
	var cgSize: CGSize { CGSize(width: width, height: height) }
	init(_ size: CGSize) {
		self.width = size.width
		self.height = size.height
	}
}

final class ImageDimensionCache: @unchecked Sendable {
	static let shared = ImageDimensionCache()

	private let lock = NSLock()
	private var sizes: [URL: CGSize] = [:]
	private var inFlight: Set<URL> = []
	private var subscribers: [UUID: @Sendable () -> Void] = [:]

	@MainActor
	private static let persistentCache = JohnnyCache<URL, ImageDimensionRecord>(
		configuration: .init(name: "markdown-image-dimensions")
	)

	func size(for url: URL) -> CGSize? {
		lock.lock(); defer { lock.unlock() }
		return sizes[url]
	}

	/// MainActor-only read that also checks the persistent JohnnyCache store.
	/// View initializers call this so `@State` is seeded with previously
	/// measured dimensions on cold launch, eliminating the first-frame reflow.
	@MainActor
	func persistedSize(for url: URL) -> CGSize? {
		if let cached = size(for: url) { return cached }
		guard let record = Self.persistentCache[url] else { return nil }
		let size = record.cgSize
		lock.lock(); sizes[url] = size; lock.unlock()
		return size
	}

	func record(_ size: CGSize, for url: URL) {
		record(size, for: url, persist: true)
	}

	private func record(_ size: CGSize, for url: URL, persist: Bool) {
		guard size.width > 0, size.height > 0 else { return }
		lock.lock()
		let changed = sizes[url] != size
		sizes[url] = size
		let callbacks = changed ? Array(subscribers.values) : []
		lock.unlock()
		if persist, changed {
			Task { @MainActor in
				Self.persistentCache[url] = ImageDimensionRecord(size)
			}
		}
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
		Task { @MainActor in
			// Check the persistent cache before paying for a network/file
			// fetch — if a previous launch already measured this URL we can
			// hydrate the in-memory dict directly and skip the load.
			if let record = Self.persistentCache[url] {
				self.releaseInFlight(url)
				self.record(record.cgSize, for: url, persist: false)
				return
			}
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
