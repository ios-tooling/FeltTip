//
//  DetailsDisclosureStateTests.swift
//  FeltTipTests
//

import Testing
@testable import FeltTip

@Suite(.serialized) @MainActor struct DetailsDisclosureStateTests {
	@Test("An expanded details block stays open after a checkbox host update")
	func expandedDetailsSurvivesCheckboxUpdate() async throws {
		let original = """
		<details>
		<summary>Checks</summary>

		- [ ] Export PDF

		</details>
		"""
		let updated = original.replacingOccurrences(of: "- [ ]", with: "- [x]")
		var toggle: (Int, Bool)?
		let harness = try await CoordinatorBridgeHarness(
			source: original,
			onCheckboxToggle: { toggle = ($0, $1) })

		try await harness.run("document.querySelector('details').open = true")
		try await harness.run("""
			var box = document.querySelector('input[data-cb="0"]');
			box.checked = true;
			box.dispatchEvent(new Event('change', { bubbles: true }));
			""")
		try await harness.waitUntil("checkbox callback") { toggle?.1 == true }

		// Marker applies the checkbox mutation to its source binding. The
		// resulting host update replaces the containing details block.
		try await harness.replaceExternally(updated)
		try await harness.waitUntil("updated checkbox rendered") {
			try await harness.evaluate(
				"document.querySelector('input[data-cb=\"0\"]').checked ? 'yes' : 'no'") == "yes"
		}
		try await harness.waitQuiescent()

		#expect(try await harness.evaluate(
			"document.querySelector('details').open ? 'open' : 'closed'") == "open")
	}
}
