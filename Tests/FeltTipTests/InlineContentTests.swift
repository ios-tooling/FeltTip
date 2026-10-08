import Foundation
import Testing
@testable import FeltTip

@Suite struct InlineContentTests {
	@Test func coalesceMergesOnlyIdenticalNeighbours() {
		var content = InlineContent()
		content.append(InlineRun("a", style: .bold))
		content.append(InlineRun("b", style: .bold))
		content.append(InlineRun("c", style: .bold, markdownSourceOffset: 5))
		content.append(InlineRun("d", style: .bold, markdownSourceOffset: 9))
		content.append(InlineRun(""))
		content.coalesce()
		#expect(content.runs.map(\.text) == ["ab", "c", "d"])
		#expect(content.characters == "abcd")
		#expect(content.characterCount == 4)
	}

	@Test func applyLinkSplitsRunsAndAdvancesStamps() {
		var content = InlineContent()
		content.append(InlineRun("see https://x.test now", markdownSourceOffset: 100))
		let url = URL(string: "https://x.test")!
		let applied = content.applyLink(url, characterRange: 4..<18)
		#expect(applied)
		#expect(content.runs.map(\.text) == ["see ", "https://x.test", " now"])
		#expect(content.runs.map(\.link) == [nil, url, nil])
		#expect(content.runs.map(\.markdownSourceOffset) == [100, 104, 118])
	}

	@Test func applyLinkRefusesLinkedOrCodeText() {
		var content = InlineContent()
		content.append(InlineRun("a ", link: URL(string: "https://a.test")))
		content.append(InlineRun("https://b.test"))
		let linkedAgain = content.applyLink(URL(string: "https://b.test")!, characterRange: 0..<16)
		#expect(!linkedAgain)
		var code = InlineContent(runs: [InlineRun("https://b.test", style: .monospaced)])
		let linkedCode = code.applyLink(URL(string: "https://b.test")!, characterRange: 0..<14)
		#expect(!linkedCode)
		#expect(code.runs.first?.link == nil)
	}

	@Test func setLinkDropsPlaceholderDimmingAndMerges() {
		var content = InlineContent()
		content.append(InlineRun("image", style: .secondary))
		content.append(InlineRun(" Deploy"))
		content.setLink(URL(string: "https://d.test")!, fromRun: 0)
		#expect(content.runs.count == 1)
		#expect(content.runs[0].text == "image Deploy")
		#expect(!content.runs[0].style.contains(.secondary))
	}

	@Test func removeFirstKeepsStampsOnRemainingText() {
		var content = InlineContent()
		content.append(InlineRun("[!NOTE] ", markdownSourceOffset: 2))
		content.append(InlineRun("rest", style: .bold, markdownSourceOffset: 10))
		content.removeFirst(characters: 8)
		#expect(content.runs.map(\.text) == ["rest"])
		#expect(content.runs[0].markdownSourceOffset == 10)
		var partial = InlineContent(runs: [InlineRun("[!TIP] 😀x", markdownSourceOffset: 0)])
		partial.removeFirst(characters: 7)
		#expect(partial.runs[0].text == "😀x")
		#expect(partial.runs[0].markdownSourceOffset == 7)
	}

	@Test func subscriptWinsOverSuperscript() {
		let style: InlineStyle = [.superscript, .subscript]
		#expect(!style.isSuperscript)
		let html = MarkdownHTMLRenderer.renderInline(InlineContent(runs: [InlineRun("x", style: style)]))
		#expect(html == "<sub>x</sub>")
	}

	@Test func attributedStringRoundTripsFormatting() {
		var content = InlineContent()
		content.append(InlineRun("bold", style: .bold, markdownSourceOffset: 3))
		content.append(InlineRun("link", link: URL(string: "https://l.test")))
		let attributed = content.attributedString(theme: .default, fontSize: 14)
		let runs = Array(attributed.runs)
		#expect(runs.count == 2)
		#expect(runs[0].inlineFontTraits == .bold)
		#expect(runs[0].markdownSourceOffset == 3)
		#expect(runs[1].link == URL(string: "https://l.test"))
		#expect(String(attributed.characters) == "boldlink")
	}
}
