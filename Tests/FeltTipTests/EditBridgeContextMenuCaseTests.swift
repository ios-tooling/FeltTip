#if os(macOS)
import Testing
@testable import FeltTip

@Suite(.serialized) @MainActor struct EditBridgeContextMenuCaseTests {
	private func dispatchCaseChange(in harness: CoordinatorBridgeHarness, cancelable: Bool) async throws {
		try await harness.run("""
			var run = document.querySelector('[data-s]');
			var text = run.firstChild;
			var selection = window.getSelection();
			var phrase = document.createRange();
			phrase.setStart(text, 0);
			phrase.setEnd(text, 11);
			selection.removeAllRanges();
			selection.addRange(phrase);
			document.body.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true }));
			var paragraph = document.createRange();
			paragraph.selectNodeContents(run);
			selection.removeAllRanges();
			selection.addRange(paragraph);
			var transfer = new DataTransfer();
			transfer.setData('text/plain', 'MIXED CASE SAMPLE.');
			var event = new InputEvent('beforeinput', {
			  inputType: 'insertText', data: null, dataTransfer: transfer,
			  bubbles: true, cancelable: \(cancelable)
			});
			Object.defineProperty(event, 'dataTransfer', { value: transfer });
			document.body.dispatchEvent(event);
			if (!\(cancelable)) {
			  text.textContent = 'MIXED CASE SAMPLE.';
			  document.body.dispatchEvent(new InputEvent('input', {
			    inputType: 'insertText', bubbles: true
			  }));
			}
			""")
	}

	@Test func cancelableTransformationUsesOriginalPhrase() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "mixed Case sample.\n")
		try await dispatchCaseChange(in: harness, cancelable: true)
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "MIXED CASE sample.\n")
		try await harness.waitQuiescent()
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func noncancelableTransformationRepairsNativeDOM() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "mixed Case sample.\n")
		try await dispatchCaseChange(in: harness, cancelable: false)
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "MIXED CASE sample.\n")
		try await harness.waitQuiescent()
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func crossRunCaseTransformationIsRefused() async throws {
		let source = "mixed **Case** sample.\n"
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.run("""
			var runs = Array.from(document.querySelectorAll('[data-s]'));
			var selection = window.getSelection();
			var phrase = document.createRange();
			phrase.setStart(runs[0].firstChild, 0);
			phrase.setEnd(runs[1].querySelector('strong').firstChild, 4);
			selection.removeAllRanges();
			selection.addRange(phrase);
			document.body.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true }));
			var paragraph = document.createRange();
			paragraph.selectNodeContents(document.querySelector('p'));
			selection.removeAllRanges();
			selection.addRange(paragraph);
			var transfer = new DataTransfer();
			transfer.setData('text/plain', 'MIXED CASE SAMPLE.');
			var event = new InputEvent('beforeinput', {
			  inputType: 'insertText', data: null, bubbles: true, cancelable: true
			});
			Object.defineProperty(event, 'dataTransfer', { value: transfer });
			document.body.dispatchEvent(event);
			window.__caseRejected = event.defaultPrevented;
			""")
		#expect(try await harness.evaluate("String(window.__caseRejected)") == "true")
		#expect(harness.source == source)
		#expect(try await harness.stampMismatches() == [])
	}
}
#endif
