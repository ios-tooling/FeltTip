#if os(macOS)
import Foundation
import Testing
@testable import FeltTip

@MainActor
struct EditBridgeDefinitionListTests {
	@Test func typingInsideDefinitionBodyEditsTheMappedSource() async throws {
		let source = "---\ntitle: Demo\n---\n\nTerm\n: A definition with **strong** text."
		let harness = try await CoordinatorBridgeHarness(source: source)
		let insertion = (source as NSString).range(of: "definition").location + 4

		try await harness.run("""
			var walker = document.createTreeWalker(
			  document.querySelector('dd'), NodeFilter.SHOW_TEXT)
			var text = walker.nextNode()
			var range = document.createRange()
			range.setStart(text, 6)
			range.collapse(true)
			var selection = window.getSelection()
			selection.removeAllRanges()
			selection.addRange(range)
			document.execCommand('insertText', false, 'X')
			""")
		try await Task.sleep(for: .milliseconds(250))
		try await harness.waitQuiescent()

		let expected = (source as NSString).replacingCharacters(
			in: NSRange(location: insertion, length: 0), with: "X")
		#expect(harness.sourceEditCount == 1)
		#expect(harness.source == expected)
		#expect(harness.coordinator.hardRejections == 0)
		#expect(try await harness.stampMismatches() == [])
	}
}
#endif
