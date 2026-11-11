//
//  EditBridgeLiteralWhitespaceTests.swift
//  FeltTipTests
//
//  The styled editor treats whitespace as source text: a physical Space or
//  Tab inserts exactly that character into the Markdown, every space and tab
//  stays visible (including at the end of a paragraph), Shift-Tab is a no-op,
//  and AppKit's double-space-to-period substitution never rewrites spaces the
//  user typed. These drive real key and input events through the edit bridge
//  in every block and inline context the editor supports.
//

#if os(macOS)
import Foundation
import Testing
@testable import FeltTip

@Suite(.serialized) @MainActor
struct EditBridgeLiteralWhitespaceTests {
	/// Marks the caret in a fixture. Not `|`, which tables need.
	nonisolated private static let caretMark = "‸"

	private func split(_ marked: String) -> (source: String, caret: Int) {
		let caret = (marked as NSString).range(of: Self.caretMark).location
		return (marked.replacingOccurrences(of: Self.caretMark, with: ""), caret)
	}

	/// Dispatch a keydown at the page and report whether the editor consumed it.
	@discardableResult
	private func press(
		_ key: String, shift: Bool = false, meta: Bool = false, control: Bool = false,
		option: Bool = false, composing: Bool = false, in harness: CoordinatorBridgeHarness
	) async throws -> Bool {
		let keyLiteral = key == "\t" ? "Tab" : key
		let result = try await harness.evaluate("""
			(function () {
			  var e = new KeyboardEvent('keydown', {
			    key: \(String(reflecting: keyLiteral)), shiftKey: \(shift), metaKey: \(meta),
			    ctrlKey: \(control), altKey: \(option), isComposing: \(composing),
			    bubbles: true, cancelable: true
			  });
			  document.body.dispatchEvent(e);
			  return String(e.defaultPrevented);
			})()
			""")
		return result == "true"
	}

	private func expectHealthy(
		_ harness: CoordinatorBridgeHarness, sourceLocation: SourceLocation = #_sourceLocation
	) async throws {
		try await harness.waitQuiescent()
		#expect(try await harness.stampMismatches() == [], sourceLocation: sourceLocation)
		#expect(harness.coordinator.hardRejections == 0, sourceLocation: sourceLocation)
	}

	// MARK: Tab and Space in every context

	nonisolated static let contexts: [String] = [
		"‸Alpha Beta",                       // paragraph start
		"Al‸pha Beta",                       // mid-word
		"Alpha ‸Beta",                       // after a space
		"Alpha Beta‸",                       // paragraph end
		"One\n\nTw‸o",                       // second paragraph
		"One\r\n\r\nTw‸o",                   // CRLF document
		"# Ti‸tle",                          // heading
		"### Deep‸",                         // heading end
		"**Bo‸ld** text",                    // inside strong
		"*It‸alic* text",                    // inside emphasis
		"~~Str‸uck~~ text",                  // inside strikethrough
		"`co‸de` text",                      // inside inline code
		"[Li‸nk](https://x.test) text",      // inside link text
		"- On‸e\n- Two",                     // bullet list
		"1. On‸e\n2. Two",                   // ordered list
		"- [ ] Ta‸sk",                       // task list
		"> Quo‸te",                          // block quote
		"> - Nes‸ted",                       // list in a quote
		"```\nlet ‸x = 1\n```",              // fenced code
		"| A‸a | Bb |\n|---|---|\n| c | d |", // table cell
	]

	@Test(arguments: contexts)
	func tabInsertsALiteralTabAndTypingFollowsIt(marked: String) async throws {
		let (source, caret) = split(marked)
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.placeCaret(caret)
		#expect(try await press("\t", in: harness), "Tab was not consumed in \(marked.debugDescription)")
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		#expect(harness.source == marked.replacingOccurrences(of: Self.caretMark, with: "\t"))
		try await harness.type("X")
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == marked.replacingOccurrences(of: Self.caretMark, with: "\tX"))
		try await expectHealthy(harness)
	}

	@Test(arguments: contexts)
	func spaceInsertsOneLiteralSpaceAndTypingFollowsIt(marked: String) async throws {
		let (source, caret) = split(marked)
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.placeCaret(caret)
		#expect(try await press(" ", in: harness), "Space was not consumed in \(marked.debugDescription)")
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		#expect(harness.source == marked.replacingOccurrences(of: Self.caretMark, with: " "))
		try await harness.type("X")
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == marked.replacingOccurrences(of: Self.caretMark, with: " X"))
		try await expectHealthy(harness)
	}

	@Test(arguments: [1, 2, 3, 5, 8])
	func consecutiveSpacesAreAllKept(count: Int) async throws {
		let harness = try await CoordinatorBridgeHarness(source: "AlphaBeta")
		try await harness.placeCaret(5)
		for index in 1...count {
			try await press(" ", in: harness)
			try await harness.waitForSourceEdits(index)
			try await harness.waitQuiescent()
		}
		let spaces = String(repeating: " ", count: count)
		#expect(harness.source == "Alpha\(spaces)Beta")
		#expect(try await harness.evaluate("document.querySelector('p').innerText") == "Alpha\(spaces)Beta")
		try await expectHealthy(harness)
	}

	@Test(arguments: [1, 2, 4])
	func consecutiveTabsAreAllKept(count: Int) async throws {
		let harness = try await CoordinatorBridgeHarness(source: "AlphaBeta")
		try await harness.placeCaret(5)
		for index in 1...count {
			try await press("\t", in: harness)
			try await harness.waitForSourceEdits(index)
			try await harness.waitQuiescent()
		}
		#expect(harness.source == "Alpha\(String(repeating: "\t", count: count))Beta")
		try await expectHealthy(harness)
	}

	// MARK: Selections

	@Test(arguments: ["\t", " "])
	func whitespaceKeyReplacesTheSelection(key: String) async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha Beta Gamma")
		try await harness.run("window.__mdPlaceCaret(6, 4)")  // "Beta"
		try await press(key, in: harness)
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		#expect(harness.source == "Alpha \(key) Gamma")
		try await harness.type("X")
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == "Alpha \(key)X Gamma")
		try await expectHealthy(harness)
	}

	@Test func tabReplacesAStyledSelectionWithoutLeavingStrayMarkers() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha **Bold** Gamma")
		try await harness.run("window.__mdPlaceCaret(8, 4)")  // the visible "Bold"
		try await press("\t", in: harness)
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		#expect(!harness.source.contains("Bold"))
		#expect(harness.source.contains("\t"))
		#expect(harness.source.hasPrefix("Alpha "))
		#expect(harness.source.hasSuffix(" Gamma"))
		try await expectHealthy(harness)
	}

	// MARK: Keys the editor must leave alone

	@Test(arguments: [
		(meta: true, control: false, option: false),
		(meta: false, control: true, option: false),
		(meta: false, control: false, option: true),
	])
	func modifiedWhitespaceKeysAreNotIntercepted(meta: Bool, control: Bool, option: Bool) async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha Beta")
		try await harness.placeCaret(5)
		for key in ["\t", " "] {
			let consumed = try await press(key, meta: meta, control: control, option: option, in: harness)
			#expect(!consumed, "modified \(key.debugDescription) was consumed")
		}
		try await Task.sleep(for: .milliseconds(200))
		#expect(harness.source == "Alpha Beta")
	}

	@Test func whitespaceKeysDuringCompositionAreLeftToTheInputMethod() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha Beta")
		try await harness.placeCaret(5)
		#expect(!(try await press(" ", composing: true, in: harness)))
		#expect(!(try await press("\t", composing: true, in: harness)))
		try await Task.sleep(for: .milliseconds(200))
		#expect(harness.source == "Alpha Beta")
	}

	@Test(arguments: ["Alpha Be‸ta", "# Ti‸tle", "- On‸e\n- Two", "> Quo‸te", "```\nlet ‸x\n```"])
	func shiftTabIsANoOpThatKeepsTheCaret(marked: String) async throws {
		let (source, caret) = split(marked)
		let harness = try await CoordinatorBridgeHarness(source: source)
		try await harness.placeCaret(caret)
		#expect(try await press("\t", shift: true, in: harness))
		try await Task.sleep(for: .milliseconds(200))
		#expect(harness.source == source)
		try await harness.type("X")
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == marked.replacingOccurrences(of: Self.caretMark, with: "X"))
		try await expectHealthy(harness)
	}

	@Test func tabOutsideTheDocumentStillMovesFocus() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha")
		let prevented = try await harness.evaluate("""
			(function () {
			  var field = document.createElement('input');
			  document.body.appendChild(field);
			  field.focus();
			  var e = new KeyboardEvent('keydown', { key: 'Tab', bubbles: true, cancelable: true });
			  field.dispatchEvent(e);
			  field.remove();
			  return String(e.defaultPrevented);
			})()
			""")
		#expect(prevented == "false")
		#expect(harness.source == "Alpha")
	}

	// MARK: Rendering

	@Test func stampedRunsPreserveWhitespaceButTheBodyDoesNot() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha  Beta\n\nGamma")
		let styles = try await harness.evaluate("""
			(function () {
			  var run = getComputedStyle(document.querySelector('[data-s]'));
			  var body = getComputedStyle(document.body);
			  return [run.whiteSpaceCollapse || run.whiteSpace, run.textWrapMode || '', run.tabSize, body.whiteSpace].join('|');
			})()
			""") ?? ""
		let parts = styles.components(separatedBy: "|")
		#expect(parts.first == "break-spaces", "run white-space: \(styles)")
		#expect(parts.dropFirst(2).first == "4", "tab-size: \(styles)")
		#expect(parts.last != "break-spaces" && parts.last != "pre-wrap", "body white-space leaked: \(styles)")
	}

	@Test func preservingWhitespaceAddsNoBlankLinesBetweenBlocks() async throws {
		let harness = try await CoordinatorBridgeHarness(
			source: "# Title\n\nAlpha  \n\n- one\n- two\n\n> quote\n\nEnd\t")
		let text = try await harness.domVisibleText()
		#expect(!text.contains("\n\n\n"), "phantom blank lines: \(text.debugDescription)")
		#expect(text.hasPrefix("Title"), "leading whitespace: \(text.debugDescription)")
	}

	@Test(arguments: ["Alpha  ", "Alpha\t", "Alpha \t ", "Alpha   \n\nBeta"])
	func trailingWhitespaceRendersAndHasWidth(source: String) async throws {
		let harness = try await CoordinatorBridgeHarness(source: source)
		let firstLine = source.components(separatedBy: "\n").first ?? source
		let trailingCount = firstLine.reversed().prefix { $0 == " " || $0 == "\t" }.count
		#expect(try await harness.evaluate("document.querySelector('p').innerText") == firstLine)
		let widths = try await harness.evaluate("""
			(function () {
			  var p = document.querySelector('p');
			  var walker = document.createTreeWalker(p, NodeFilter.SHOW_TEXT);
			  var text = '', nodes = [], n;
			  while ((n = walker.nextNode())) { nodes.push([n, text.length]); text += n.nodeValue; }
			  var out = [];
			  for (var i = text.length - \(trailingCount); i < text.length; i++) {
			    for (var k = nodes.length - 1; k >= 0; k--) {
			      if (i >= nodes[k][1]) {
			        var r = document.createRange();
			        r.setStart(nodes[k][0], i - nodes[k][1]); r.setEnd(nodes[k][0], i - nodes[k][1] + 1);
			        out.push(r.getBoundingClientRect().width > 0);
			        break;
			      }
			    }
			  }
			  return JSON.stringify(out);
			})()
			""")
		#expect(widths == "[" + Array(repeating: "true", count: trailingCount).joined(separator: ",") + "]")
		#expect(try await harness.stampMismatches() == [])
	}

	@Test(arguments: ["A", "Abc", "Abcdef"])
	func aTabEndsOnTheNextFourSpaceStop(prefix: String) async throws {
		// tab-size: 4 puts tab stops every four space widths from the line start.
		// Forty spaces give the interval without whole-pixel rounding error.
		let harness = try await CoordinatorBridgeHarness(source: "A\(String(repeating: " ", count: 40))B\n\n\(prefix)\tB")
		let measured = try await harness.evaluate("""
			(function () {
			  function rect(p, ch) {
			    var walker = document.createTreeWalker(p, NodeFilter.SHOW_TEXT), n;
			    while ((n = walker.nextNode())) {
			      var i = n.nodeValue.indexOf(ch);
			      if (i < 0) continue;
			      var r = document.createRange(); r.setStart(n, i); r.setEnd(n, i + ch.length);
			      return r.getBoundingClientRect();
			    }
			    return null;
			  }
			  var ps = document.querySelectorAll('p');
			  var fourSpaces = rect(ps[0], ' '.repeat(40)), tab = rect(ps[1], '\\t');
			  if (!fourSpaces || !tab) return '[]';
			  return JSON.stringify([fourSpaces.width / 10, tab.width, tab.right - ps[1].getBoundingClientRect().left]);
			})()
			""") ?? "[]"
		let values = try JSONDecoder().decode([Double].self, from: Data(measured.utf8))
		try #require(values.count == 3, "measurement failed: \(measured)")
		let (interval, tab, tabEnd) = (values[0], values[1], values[2])
		#expect(interval > 0)
		#expect(tab > 0, "the tab collapsed to zero width")
		let stop = (tabEnd / interval).rounded() * interval
		#expect(abs(tabEnd - stop) <= 1.0, "tab ends at \(tabEnd), nearest 4-space stop is \(stop)")
	}

	@Test func stampedFencedCodeStaysEditable() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Intro\n\n```\nlet x = 1\n```")
		#expect(try await harness.evaluate("document.querySelector('pre').contentEditable") != "false")
	}

	// MARK: Deleting whitespace

	@Test func backspacingThroughTrailingSpacesReachesTheWord() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha   ")
		try await harness.placeCaret(8)
		for remaining in [2, 1, 0] {
			try await harness.run("document.execCommand('delete')")
			try await harness.waitForSourceEdits(3 - remaining)
			try await harness.waitQuiescent()
			#expect(harness.source == "Alpha" + String(repeating: " ", count: remaining))
		}
		try await harness.type("X")
		try await harness.waitForSourceEdits(4)
		#expect(harness.source == "AlphaX")
		try await expectHealthy(harness)
	}

	@Test func forwardDeleteRemovesOneTrailingCharacter() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha \t")
		try await harness.placeCaret(5)
		try await harness.run("document.execCommand('forwardDelete')")
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		#expect(harness.source == "Alpha\t")
		try await expectHealthy(harness)
	}

	@Test func deletingATabRemovesExactlyTheTab() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Alpha\t\tBeta")
		try await harness.placeCaret(7)
		try await harness.run("document.execCommand('delete')")
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		#expect(harness.source == "Alpha\tBeta")
		try await expectHealthy(harness)
	}

	@Test func trailingWhitespaceSurvivesAnUnrelatedEditElsewhere() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "One\n\nAlpha  ")
		try await harness.type("Z", at: 3)
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		#expect(harness.source == "OneZ\n\nAlpha  ")
		#expect(try await harness.evaluate("document.querySelectorAll('p')[1].innerText") == "Alpha  ")
		try await expectHealthy(harness)
	}

	// MARK: Rapid input

	@Test(arguments: [
		([" ", " ", " "], "Alpha   XBeta"),
		(["\t", " ", "\t"], "Alpha\t \tXBeta"),
		([" ", "\t", " ", "\t"], "Alpha \t \tXBeta"),
	])
	func rapidWhitespaceAndTypingReplayInOrder(keys: [String], expected: String) async throws {
		let harness = try await CoordinatorBridgeHarness(source: "AlphaBeta")
		try await harness.placeCaret(5)
		let presses = keys.map { key in
			"document.body.dispatchEvent(new KeyboardEvent('keydown', {key: \(String(reflecting: key == "\t" ? "Tab" : key)), bubbles: true, cancelable: true}))"
		}.joined(separator: ";")
		try await harness.run("\(presses); document.execCommand('insertText', false, 'X')")
		try await harness.waitUntil("rapid whitespace converged") { harness.source == expected }
		try await harness.waitQuiescent()
		#expect(harness.source == expected)
		try await expectHealthy(harness)
	}

	@Test func bufferedTypingThatContainsATabStaysLiteral() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "AlphaBeta")
		try await harness.placeCaret(5)
		try await harness.run("""
			document.body.dispatchEvent(new KeyboardEvent('keydown', {key: 'Tab', bubbles: true, cancelable: true}));
			document.execCommand('insertText', false, 'a\\tb');
			""")
		try await harness.waitUntil("buffered tab text converged") { harness.source == "Alpha\ta\tbBeta" }
		try await expectHealthy(harness)
	}

	// MARK: Double-space period substitution

	private func pressSpaceThenSubstitute(
		_ harness: CoordinatorBridgeHarness, inputType: String = "insertText", text: String = ". "
	) async throws -> Bool {
		try await press(" ", in: harness)
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		let prevented = try await harness.evaluate("""
			(function () {
			  window.__mdPlaceCaret(5, 1);
			  var e = new InputEvent('beforeinput', {
			    inputType: '\(inputType)', data: \(String(reflecting: text)), bubbles: true, cancelable: true
			  });
			  var r = window.getSelection().getRangeAt(0).cloneRange();
			  Object.defineProperty(e, 'getTargetRanges', { value: function () { return [r]; } });
			  document.body.dispatchEvent(e);
			  return String(e.defaultPrevented);
			})()
			""")
		return prevented == "true"
	}

	@Test(arguments: [
		("insertText", ". "), ("insertText", "."),
		("insertReplacementText", ". "), ("insertReplacementText", "."),
	])
	func periodSubstitutionRightAfterASpaceIsRejected(inputType: String, text: String) async throws {
		let harness = try await CoordinatorBridgeHarness(source: "AlphaBeta")
		try await harness.placeCaret(5)
		#expect(try await pressSpaceThenSubstitute(harness, inputType: inputType, text: text))
		try await Task.sleep(for: .milliseconds(200))
		#expect(harness.source == "Alpha Beta")
		try await expectHealthy(harness)
	}

	@Test func otherTextRightAfterASpaceIsNotMistakenForSubstitution() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "AlphaBeta")
		try await harness.placeCaret(5)
		try await press(" ", in: harness)
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		try await harness.type(",")
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == "Alpha ,Beta")
		try await expectHealthy(harness)
	}

	@Test func aPeriodTypedWithoutARecentSpaceIsKept() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "AlphaBeta")
		try await harness.type(".", at: 5)
		try await harness.waitForSourceEdits(1)
		#expect(harness.source == "Alpha.Beta")
		try await expectHealthy(harness)
	}

	@Test func aPeriodAfterTheSpaceWindowExpiresIsKept() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "AlphaBeta")
		try await harness.placeCaret(5)
		try await press(" ", in: harness)
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		try await Task.sleep(for: .milliseconds(1_150))
		try await harness.type(".", at: 6)
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == "Alpha .Beta")
		try await expectHealthy(harness)
	}

	@Test func anotherKeyBetweenSpaceAndPeriodClearsTheGuard() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "AlphaBeta")
		try await harness.placeCaret(5)
		try await press(" ", in: harness)
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		try await harness.run("""
			document.body.dispatchEvent(new KeyboardEvent('keydown', {key: '.', bubbles: true}));
			window.__mdPlaceCaret(6);
			document.execCommand('insertText', false, '.');
			""")
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == "Alpha .Beta")
		try await expectHealthy(harness)
	}

	@Test func aClickBetweenSpaceAndPeriodClearsTheGuard() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "AlphaBeta")
		try await harness.placeCaret(5)
		try await press(" ", in: harness)
		try await harness.waitForSourceEdits(1)
		try await harness.waitQuiescent()
		try await harness.run("""
			document.body.dispatchEvent(new PointerEvent('pointerdown', {bubbles: true}));
			window.__mdPlaceCaret(6);
			document.execCommand('insertText', false, '.');
			""")
		try await harness.waitForSourceEdits(2)
		#expect(harness.source == "Alpha .Beta")
		try await expectHealthy(harness)
	}

	@Test func aRejectedSubstitutionDoesNotSwallowTheNextSpace() async throws {
		// AppKit can leave the previous space selected after a rejected
		// replacement; the next Space must land after it, not replace it.
		let harness = try await CoordinatorBridgeHarness(source: "AlphaBeta")
		try await harness.placeCaret(5)
		#expect(try await pressSpaceThenSubstitute(harness))
		try await harness.run("window.__mdPlaceCaret(5, 1)")
		try await press(" ", in: harness)
		try await harness.waitForSourceEdits(2)
		try await harness.waitQuiescent()
		#expect(harness.source == "Alpha  Beta")
		try await expectHealthy(harness)
	}
}
#endif
