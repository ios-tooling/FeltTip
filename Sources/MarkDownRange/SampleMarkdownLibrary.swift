//
//  SampleMarkdownLibrary.swift
//  MarkDownRange
//
//  Exposes the corpus of sample markdown documents shipped at the package
//  root under `Misc/sample_markdowns/`. Useful for tests and demo harnesses
//  that want a real document to feed the renderer without checking copies
//  into the consumer's own tree. The corpus location is derived from this
//  file's compile-time `#filePath`, so it's bound to MarkDownRange's source
//  checkout — fine for tests/dev tooling, not for production runtime use.
//

import Foundation

public enum SampleMarkdownLibrary {
	/// Directory containing the bundled `*.md` / `*.markdown` samples.
	public static let directoryURL: URL = {
		let here = URL(fileURLWithPath: #filePath, isDirectory: false)
		// here: …/Sources/MarkDownRange/SampleMarkdownLibrary.swift
		let packageRoot = here
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
		return packageRoot.appendingPathComponent("Misc/sample_markdowns")
	}()

	/// URL of a single sample document. Does not check that the file
	/// actually exists; callers needing that should `FileManager.fileExists`
	/// before opening.
	public static func fixtureURL(named filename: String) -> URL {
		directoryURL.appendingPathComponent(filename)
	}
}
