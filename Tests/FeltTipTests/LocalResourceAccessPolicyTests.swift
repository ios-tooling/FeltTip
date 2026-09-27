//
//  LocalResourceAccessPolicyTests.swift
//  FeltTipTests
//

import Foundation
import Testing
@testable import FeltTip

@Suite struct LocalResourceAccessPolicyTests {
	@Test func confinesRequestsToTheAuthorizedRootAndSupportedTypes() throws {
		let parent = FileManager.default.temporaryDirectory
			.appendingPathComponent("resource-policy-\(UUID().uuidString)", isDirectory: true)
		let root = parent.appendingPathComponent("document", isDirectory: true)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: parent) }

		let image = root.appendingPathComponent("image.png")
		let text = root.appendingPathComponent("secret.txt")
		let outside = parent.appendingPathComponent("outside.png")
		try Data([0x89, 0x50, 0x4e, 0x47]).write(to: image)
		try Data("secret".utf8).write(to: text)
		try Data([0x89]).write(to: outside)

		let policy = LocalResourceAccessPolicy()
		policy.setRoot(root)
		#expect(policy.authorizedFileURL(for: requestURL(image)) == image.resolvingSymlinksInPath())
		#expect(policy.authorizedFileURL(for: requestURL(text)) == nil)
		#expect(policy.authorizedFileURL(for: requestURL(outside)) == nil)
		#expect(policy.authorizedFileURL(for: requestURL(outside, host: "other")) == nil)
	}

	@Test func resolvingSymlinksCannotEscapeTheRoot() throws {
		let parent = FileManager.default.temporaryDirectory
			.appendingPathComponent("resource-symlink-\(UUID().uuidString)", isDirectory: true)
		let root = parent.appendingPathComponent("document", isDirectory: true)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: parent) }
		let outside = parent.appendingPathComponent("outside.png")
		let link = root.appendingPathComponent("linked.png")
		try Data([0x89]).write(to: outside)
		try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

		let policy = LocalResourceAccessPolicy()
		policy.setRoot(root)
		#expect(policy.authorizedFileURL(for: requestURL(link)) == nil)
	}

	@Test func oversizedLocalResourcesAreRejectedBeforeTheyAreLoaded() throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("resource-size-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: root) }
		let oversized = root.appendingPathComponent("oversized.png")
		FileManager.default.createFile(atPath: oversized.path, contents: Data())
		let handle = try FileHandle(forWritingTo: oversized)
		try handle.truncate(atOffset: UInt64(LocalResourceAccessPolicy.maximumResourceBytes + 1))
		try handle.close()

		let policy = LocalResourceAccessPolicy()
		policy.setRoot(root)
		#expect(policy.authorizedFileURL(for: requestURL(oversized)) == nil)
		do {
			_ = try ImageDataLoader.localData(from: oversized)
			Issue.record("Expected the oversized image load to fail")
		} catch let error as URLError {
			#expect(error.code == .dataLengthExceedsMaximum)
		}
	}

	private func requestURL(_ file: URL, host: String = "res") -> URL {
		var components = URLComponents()
		components.scheme = "markerlocalres"
		components.host = host
		components.path = file.path
		return components.url!
	}
}
