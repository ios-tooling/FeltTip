//
//  SnapshotBundle.swift
//  MarkDownRangeTests
//

#if os(macOS)
import Foundation
import AppKit
@testable import MarkDownRange

/// In-memory shape of a recorded .markerSnap. The replayer rebuilds a
/// matching render context from `metadata` and pixel-diffs the result
/// against `reference`.
struct SnapshotBundle {
	let url: URL
	let metadata: Metadata
	let source: String
	let reference: NSImage

	struct Metadata: Codable, Sendable {
		var name: String
		var contentSize: CGSize
		var scrollFraction: Double
		var theme: String
		var themeColors: MarkdownThemeSnapshot?
		var fontSize: Double
		var viewMode: String
		/// Optional — set on schema v3+. The replayer mirrors the
		/// document window's WidthConstrainedView by horizontally
		/// padding FormattedMarkdownScreen so it fills exactly this
		/// many points (centered). nil ⇒ content fills the full width.
		var contentMaxWidth: Double?
		/// Optional — set on schema v3+. Height of the document status
		/// bar that was in the capture; replayer reserves a matching
		/// strip at the bottom so heights line up.
		var statusBarHeight: Double?
		var capturedAt: Date
		var schemaVersion: Int
	}

	enum LoadError: Error {
		case missingReferenceImage(URL)
	}

	static func load(_ url: URL) throws -> SnapshotBundle {
		let meta = try JSONDecoder().decode(
			Metadata.self,
			from: Data(contentsOf: url.appendingPathComponent("metadata.json"))
		)
		let source = try String(
			contentsOf: url.appendingPathComponent("source.md"),
			encoding: .utf8
		)
		let referenceURL = url.appendingPathComponent("reference.png")
		guard let reference = NSImage(contentsOf: referenceURL) else {
			throw LoadError.missingReferenceImage(referenceURL)
		}
		return SnapshotBundle(url: url, metadata: meta, source: source, reference: reference)
	}

	/// `Snapshots/Bundles/` next to this source file. Using `#filePath`
	/// keeps the path stable across machines and CI.
	static var bundlesDirectory: URL {
		URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.appendingPathComponent("Bundles", isDirectory: true)
	}

	static func discoverAll() -> [URL] {
		let fm = FileManager.default
		guard let entries = try? fm.contentsOfDirectory(
			at: bundlesDirectory,
			includingPropertiesForKeys: nil
		) else { return [] }
		return entries
			.filter { $0.pathExtension == "markerSnap" }
			.sorted { $0.lastPathComponent < $1.lastPathComponent }
	}
}
#endif
