//
//  EditBridgeCheckboxRevisionTests.swift
//  MarkDownRangeTests
//

#if os(macOS)
import Testing
@testable import MarkDownRange

@Suite(.serialized) @MainActor struct EditBridgeCheckboxRevisionTests {
	@Test func checkboxClickIsRevisionGatedAndSourceVerified() async throws {
		var toggles: [(Int, Bool)] = []
		let source = "- [ ] first\n- [ ] second\n"
		let harness = try await CoordinatorBridgeHarness(
			source: source,
			onCheckboxToggle: { toggles.append(($0, $1)) })

		try await harness.run("""
			var box = document.querySelector('input[data-cb="0"]');
			box.checked = true;
			box.dispatchEvent(new Event('change', { bubbles: true }));
			""")
		try await harness.waitUntil("current checkbox callback") { toggles.count == 1 }
		#expect(toggles.first?.0 == 0)
		#expect(toggles.first?.1 == true)

		let hostText = "- [ ] inserted\n" + source
		try await harness.replaceExternally(hostText)
		// The old page's index 0 now names a different source item. A stale
		// event must not reach the host callback.
		try await harness.run("""
			var oldBox = document.querySelector('input[data-cb="0"]');
			oldBox.checked = false;
			oldBox.dispatchEvent(new Event('change', { bubbles: true }));
			""")
		try await harness.waitUntil("checkbox host update committed") {
			harness.coordinator.currentSource == hostText
		}
		try await harness.waitQuiescent()
		try await Task.sleep(for: .milliseconds(100))
		#expect(toggles.count == 1)
		#expect(harness.coordinator.resyncCount == 0)
	}
}
#endif
