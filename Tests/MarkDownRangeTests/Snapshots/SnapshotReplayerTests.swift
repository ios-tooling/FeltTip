//
//  SnapshotReplayerTests.swift
//  MarkDownRangeTests
//

#if os(macOS)
import Testing
import Foundation
import AppKit

@Suite("Snapshot bundle replay", .serialized)
@MainActor
struct SnapshotReplayerTests {

	@Test("Every recorded bundle still matches the engine render", arguments: SnapshotBundle.discoverAll())
	func replay(bundleURL: URL) async throws {
		let bundle = try SnapshotBundle.load(bundleURL)
		guard let rendered = await SnapshotReplayer.render(bundle) else {
			Issue.record("Replayer returned no image for \(bundle.metadata.name)")
			return
		}
		let result = SnapshotImageDiffer.compare(rendered, bundle.reference)
		if result.sizeMismatch {
			let rSize = rendered.size
			let bSize = bundle.reference.size
			Issue.record("\(bundle.metadata.name): size mismatch (rendered \(rSize) vs reference \(bSize))")
			writeFailureArtifacts(rendered: rendered, bundle: bundle)
			return
		}
		// 1.5% tolerance covers font-hinting/anti-aliasing drift across runs
		// while still catching real layout changes.
		let pct = result.differingPixelFraction * 100
		if result.differingPixelFraction >= 0.015 {
			let path = writeFailureArtifacts(rendered: rendered, bundle: bundle)
			Issue.record("\(bundle.metadata.name): \(String(format: "%.2f", pct))% pixel diff (rendered written to \(path?.path ?? "n/a"))")
		}
	}

	/// On a failing diff, drop the rendered PNG into a temp directory so
	/// the dev can pixel-compare against the reference without re-running
	/// the test. Returns the path so we can echo it in the failure message.
	@discardableResult
	private func writeFailureArtifacts(rendered: NSImage, bundle: SnapshotBundle) -> URL? {
		let dir = FileManager.default.temporaryDirectory
			.appendingPathComponent("MarkerSnapshotDiffs", isDirectory: true)
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		let url = dir.appendingPathComponent("\(bundle.metadata.name)-rendered.png")
		guard let cg = rendered.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
		let bitmap = NSBitmapImageRep(cgImage: cg)
		try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
		return url
	}
}
#endif
