//
//  FormattingScrollStabilityTests.swift
//  FeltTip
//
//  Restoring a selection after a style toggle must not move the page. Only a
//  pane handoff, which the host flags explicitly, centers its selection.
//

import Foundation
import Testing
@testable import FeltTip

@MainActor @Suite struct FormattingScrollStabilityTests {
	@Test func boldToggleKeepsAMouseSelectionWhereItWas() async throws {
		let paragraphs = (0..<800).map {
			"Paragraph \($0) with enough text to make this a realistically tall styled document."
		}
		let harness = try await CoordinatorBridgeHarness(source: paragraphs.joined(separator: "\n\n"))
		// Select "Paragraph 400" the way a mouse drag would, with the block
		// sitting just below the viewport top rather than centered.
		try await harness.run("""
			var blocks = Array.from(document.body.children).filter(e => e.querySelector && e.querySelector('[data-s]'));
			window.scrollTo(0, blocks[400].offsetTop - 20);
			var text = blocks[400].querySelector('[data-s]').firstChild;
			var r = document.createRange(); r.setStart(text, 0); r.setEnd(text, 13);
			var s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
			window.__testScrollY = window.scrollY;
			""")
		try await harness.run("window.__mdApplyFormat('bold')")
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()

		#expect(harness.source.contains("**Paragraph 400**"))
		#expect(try await harness.evaluate("window.getSelection().toString()") == "Paragraph 400")
		let delta = try await harness.evaluate("String(Math.abs(window.scrollY - window.__testScrollY))").flatMap(Double.init) ?? .infinity
		#expect(delta < 60, "bold toggle moved the page \(delta)px")
	}
}
