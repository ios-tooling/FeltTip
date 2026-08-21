//
//  EditBridgeTextSubstitutionTests.swift
//  MarkDownRangeTests
//
//  Dictation and predictive text, which reach the page as a composition rather
//  than as mappable per-keystroke events: marked text sits in the DOM that the
//  source doesn't have, so the bridge snapshots the run at compositionstart and
//  reconciles the whole run at compositionend.
//
//  These drive the composition events directly, which is faithful because the
//  handler's contract is to diff the run at the end — it deliberately doesn't
//  trust anything the events carry. What that leaves uncovered is the software
//  keyboard's own behaviour: whether iOS fires these events where we expect for
//  every substitution feature. That needs a host app and a real keyboard.
//

import Testing
@testable import MarkDownRange

@Suite(.serialized) @MainActor struct EditBridgeTextSubstitutionTests {
	/// Start a composition with the caret at `offset`, run `mutate` against the
	/// composing run the way an IME or dictation commit would, then end it.
	private func compose(
		in harness: CoordinatorBridgeHarness,
		at offset: Int,
		mutate: String
	) async throws {
		try await harness.run("window.__mdPlaceCaret(\(offset))")
		try await harness.run("""
			document.body.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
			""")
		try await harness.run(mutate)
		try await harness.run("""
			document.body.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true }));
			""")
	}

	/// The run holding `offset`, as the page sees it.
	private func runScript(at offset: Int) -> String {
		"""
		var stamps = window.__mdStamps();
		var found = null;
		for (var i = 0; i < stamps.els.length; i++) {
			var base = stamps.bases[i];
			if (base <= \(offset) && \(offset) <= base + stamps.els[i].textContent.length) { found = stamps.els[i]; }
		}
		"""
	}

	@Test func dictationCommittingIntoARunSplicesTheSource() async throws {
		// Dictation lands its text by mutating the DOM under a composition. The
		// source only finds out at compositionend, from the run diff.
		let harness = try await CoordinatorBridgeHarness(source: "The quick fox\n")
		try await compose(in: harness, at: 4, mutate: """
			\(runScript(at: 4))
			found.firstChild.textContent = 'The quick brown fox';
			""")
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "The quick brown fox\n")
		try await harness.waitQuiescent()
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func aCompositionThatChangesNothingLeavesTheSourceAlone() async throws {
		// Dismissing a prediction without taking it ends the composition with
		// the run exactly as it started. Posting an edit for that would churn
		// the source and move the caret for nothing.
		let harness = try await CoordinatorBridgeHarness(source: "The quick fox\n")
		try await compose(in: harness, at: 4, mutate: "void 0;")
		try await Task.sleep(for: .milliseconds(300))
		#expect(harness.source == "The quick fox\n")
		#expect(harness.sourceEditCount == 0)
		#expect(try await harness.stampMismatches() == [])
	}

	@Test func dictationReplacingAWholeRunKeepsTheMarkersOutOfTheSource() async throws {
		// The composing run is the text inside **bold**, not the markers. A
		// diff that reached past them would write the markers into the source
		// twice or lose them entirely.
		let harness = try await CoordinatorBridgeHarness(source: "a **bold** b\n")
		let inner = ("a **bold** b\n" as NSString).range(of: "bold").location
		try await compose(in: harness, at: inner, mutate: """
			\(runScript(at: inner))
			found.firstChild.textContent = 'BRAVE';
			""")
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "a **BRAVE** b\n")
		try await harness.waitQuiescent()
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.hardRejections == 0)
	}

	@Test func aCompositionSpanningTwoRunsResyncsRatherThanGuessing() async throws {
		// A selection that starts in one run and ends in another can't be
		// reconciled by diffing one run, so compositionstart marks it desynced
		// and compositionend asks for a re-render. The rule from EDITING.md:
		// never guess, resync.
		let harness = try await CoordinatorBridgeHarness(source: "a **bold** b\n")
		try await harness.run("""
			var stamps = window.__mdStamps();
			var sel = window.getSelection();
			var range = document.createRange();
			range.setStart(stamps.els[0].firstChild, 0);
			range.setEnd(stamps.els[stamps.els.length - 1].firstChild, 1);
			sel.removeAllRanges();
			sel.addRange(range);
			document.body.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
			document.body.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true }));
			""")
		try await harness.waitQuiescent()
		// The source is untouched — a desync re-renders from what the host
		// already holds; it never writes a guess back.
		#expect(harness.source == "a **bold** b\n")
		#expect(try await harness.stampMismatches() == [])
		#expect(harness.coordinator.hardRejections == 0)
	}
}
