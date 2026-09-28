//
//  MarkdownMeta.swift
//  FeltTip
//

import Foundation

/// Metadata extracted from a parsed markdown document — counts, headings,
/// links, images, code blocks, and frontmatter.
public struct MarkdownMeta: Sendable, Equatable {
	/// The whitespace counter below sees `- [ ]` as three source tokens but
	/// `- [x]` as two. Exclude both forms of task-list markup so checking an
	/// item never changes the displayed word count.
	private static let taskMarker = try! NSRegularExpression(
		pattern: #"(?m)^[ \t]*(?:[-+*]|[0-9]+[.)])[ \t]+\[([ xX])\](?=[ \t\r\n]|$)"#)
	public let wordCount: Int
	public let characterCount: Int
	public let lineCount: Int
	public let readingTime: String

	public let headings: [Heading]
	public let links: [Link]
	public let images: [Image]
	public let codeBlocks: [CodeBlock]
	public let frontmatter: [FrontmatterPair]

	public struct Heading: Sendable, Equatable {
		public let level: Int
		public let text: String
	}

	public struct Link: Sendable, Equatable {
		public let url: String
		public let text: String
	}

	public struct Image: Sendable, Equatable {
		public let source: String
		public let alt: String
	}

	public struct CodeBlock: Sendable, Equatable {
		public let language: String?
		public let lineCount: Int
	}

	public struct FrontmatterPair: Sendable, Equatable {
		public let key: String
		public let value: String
	}

	public init(_ content: some MarkdownContent) {
		let text = content.resolveMarkdown()
		let blocks = MarkdownBlockParser.parse(text)
		self.init(text: text, blocks: blocks)
	}

	public init(text: String, blocks: [MarkdownBlock]) {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		var characterCount = 0
		var wordCount = 0
		var inWord = false
		for character in trimmed {
			characterCount += 1
			if character.isWhitespace || character.isNewline {
				inWord = false
			} else if !inWord {
				wordCount += 1
				inWord = true
			}
		}
		self.characterCount = characterCount
		let source = text as NSString
		for match in Self.taskMarker.matches(in: text, range: NSRange(location: 0, length: source.length)) {
			// The bullet/ordinal is one token. An empty checkbox is two
			// whitespace-separated tokens; a checked one is a single token.
			wordCount -= source.character(at: match.range(at: 1).location) == 0x20 ? 3 : 2
		}
		self.wordCount = max(0, wordCount)

		// `components(separatedBy:)` allocated one String per source line even
		// though metadata needs only the count. Character treats CRLF as one
		// newline grapheme and recognizes the same Unicode newline family.
		var lineCount = 1
		for character in text where character.isNewline { lineCount += 1 }
		self.lineCount = lineCount

		let minutes = max(1, Int(ceil(Double(wordCount) / 200.0)))
		self.readingTime = minutes == 1 ? "1 min read" : "\(minutes) min read"

		var walker = MarkdownMetaWalker()
		walker.walk(blocks)
		self.headings = walker.headings
		self.links = walker.links
		self.images = walker.images
		self.codeBlocks = walker.codeBlocks
		self.frontmatter = walker.frontmatter
	}
}

extension MarkdownMeta {
	public var hasFrontmatter: Bool { !frontmatter.isEmpty }
	public var hasLinks: Bool { !links.isEmpty }
	public var hasImages: Bool { !images.isEmpty }
	public var hasCodeBlocks: Bool { !codeBlocks.isEmpty }

	public func frontmatterValue(for key: String) -> String? {
		frontmatter.first { $0.key == key }?.value
	}

	public var codeBlockLanguages: [String] {
		codeBlocks.compactMap(\.language)
	}
}
