import Testing
import Foundation
@testable import FeltTip

@Suite struct MarkdownMetaSampleTests {
	static let samplesDirectory: URL = {
		var url = URL(fileURLWithPath: #filePath)
		// .../Tests/FeltTipTests/MarkdownMetaSampleTests.swift
		url.deleteLastPathComponent() // FeltTipTests
		url.deleteLastPathComponent() // Tests
		url.deleteLastPathComponent() // <repo root>
		return url.appendingPathComponent("Misc/sample_markdowns")
	}()

	static let sampleFiles: [URL] = {
		let fm = FileManager.default
		guard let entries = try? fm.contentsOfDirectory(
			at: samplesDirectory,
			includingPropertiesForKeys: nil,
			options: [.skipsHiddenFiles]
		) else { return [] }
		return entries
			.filter { ["md", "markdown"].contains($0.pathExtension.lowercased()) }
			.sorted { $0.lastPathComponent < $1.lastPathComponent }
	}()

	@Test func samplesDirectoryExists() {
		var isDir: ObjCBool = false
		let exists = FileManager.default.fileExists(atPath: Self.samplesDirectory.path, isDirectory: &isDir)
		#expect(exists, "Expected sample directory at \(Self.samplesDirectory.path)")
		#expect(isDir.boolValue)
		#expect(!Self.sampleFiles.isEmpty, "Expected at least one .md file in samples")
	}

	@Test(arguments: sampleFiles)
	func meta(for file: URL) throws {
		let text = try String(contentsOf: file, encoding: .utf8)
		let meta = MarkdownMeta(text)

		#expect(meta.characterCount >= 0)
		#expect(meta.wordCount >= 0)
		#expect(meta.lineCount >= 1)
		#expect(!meta.readingTime.isEmpty)

		for link in meta.links {
			#expect(!link.url.isEmpty, "Empty URL in \(file.lastPathComponent)")
		}
		for image in meta.images {
			#expect(!image.source.isEmpty, "Empty image source in \(file.lastPathComponent)")
		}
		for heading in meta.headings {
			#expect((1...6).contains(heading.level), "Bad heading level in \(file.lastPathComponent)")
		}
		for pair in meta.frontmatter {
			#expect(!pair.key.isEmpty, "Empty frontmatter key in \(file.lastPathComponent)")
		}

		// Counts should track the trimmed source.
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		#expect(meta.characterCount == trimmed.count)
	}
}
