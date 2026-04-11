import Testing
import Foundation
@testable import MarkDownRange

@Suite struct EmojiTests {
	@Test func basicEmoji() {
		let result = EmojiShortcodes.process("Hello :smile: world")
		#expect(result == "Hello 😄 world")
	}

	@Test func multipleEmojis() {
		let result = EmojiShortcodes.process(":rocket: Launch :fire: Hot")
		#expect(result.contains("🚀"))
		#expect(result.contains("🔥"))
	}

	@Test func unknownShortcode() {
		let result = EmojiShortcodes.process("Hello :nonexistent: world")
		#expect(result == "Hello :nonexistent: world")
	}

	@Test func noShortcodes() {
		let result = EmojiShortcodes.process("Plain text no emojis")
		#expect(result == "Plain text no emojis")
	}

	@Test func shortcodeInCode() {
		// In real markdown, code blocks would prevent this — but the shortcode
		// processor runs on raw text. This tests the regex itself.
		let result = EmojiShortcodes.process(":thumbsup:")
		#expect(result == "👍")
	}

	@Test func plusOneShortcode() {
		#expect(EmojiShortcodes.process(":+1:") == "👍")
	}

	@Test func emojiInParsedMarkdown() {
		let blocks = MarkdownBlockParser.parse("Hello :rocket: world")
		guard case .paragraph(let content, _, _) = blocks.first else {
			Issue.record("Expected paragraph"); return
		}
		let text = String(content.characters)
		#expect(text.contains("🚀"))
	}

	@Test func emojiInHeading() {
		let blocks = MarkdownBlockParser.parse("# :tada: Celebration")
		guard case .heading(_, let content, _) = blocks.first else {
			Issue.record("Expected heading"); return
		}
		#expect(String(content.characters).contains("🎉"))
	}
}
