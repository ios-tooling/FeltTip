import Testing
@testable import FeltTip

@Suite struct EmoticonShortcodesTests {
	@Test func basicSmile() {
		#expect(EmoticonShortcodes.process("hello :-)") == "hello 🙂")
		#expect(EmoticonShortcodes.process(":) world") == "🙂 world")
	}

	@Test func longAndShortFrowns() {
		#expect(EmoticonShortcodes.process("oh :-(") == "oh 🙁")
		#expect(EmoticonShortcodes.process(":(") == "🙁")
	}

	@Test func wink() {
		#expect(EmoticonShortcodes.process("wink ;)") == "wink 😉")
		#expect(EmoticonShortcodes.process(";-)") == "😉")
	}

	@Test func sunglasses() {
		#expect(EmoticonShortcodes.process("cool 8-)") == "cool 😎")
	}

	@Test func preservesAdjacentPunctuation() {
		#expect(EmoticonShortcodes.process("really? :-).") == "really? 🙂.")
	}

	@Test func doesNotMatchInsideWord() {
		// `a:)b` shouldn't be rewritten because there's no word boundary
		#expect(EmoticonShortcodes.process("a:)b") == "a:)b")
	}

	@Test func skipsInsideInlineCode() {
		#expect(EmoticonShortcodes.process("see `:-)`") == "see `:-)`")
	}
}
