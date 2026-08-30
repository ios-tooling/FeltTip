import Foundation
import Testing
@testable import MarkDownRange

@Suite struct MarkdownWebViewScriptsTests {
	@Test func directResourceLookupIgnoresAStaleNestedScript() throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		defer { try? FileManager.default.removeItem(at: root) }
		try FileManager.default.createDirectory(
			at: root.appendingPathComponent("Resources", isDirectory: true),
			withIntermediateDirectories: true)
		let current = root.appendingPathComponent("EditorScript.js")
		let stale = root.appendingPathComponent("Resources/EditorScript.js")
		try "current".write(to: current, atomically: true, encoding: .utf8)
		try "stale".write(to: stale, atomically: true, encoding: .utf8)

		let selected = try #require(MarkdownWebViewScripts.directResourceURL(
			"EditorScript", resourceRoot: root))
		#expect(selected.standardizedFileURL == current.standardizedFileURL)
		#expect(try String(contentsOf: selected, encoding: .utf8) == "current")
	}
}
