import Foundation
import Testing
@testable import FeltTip

/// The editable web view maps caret positions to the source as
/// `data-s + UTF-16 chars into the run`, which is only sound when every
/// stamped run's rendered text sits verbatim at its stamp. These tests verify
/// that property over whole rendered documents: every `<span data-s="N">` must
/// contain exactly the source text at N, and runs that can't satisfy it
/// (entity references and other rewrites) must go unstamped.
@Suite struct SourceOffsetStampingTests {
	/// All `<span data-s="N">…</span>` runs as (offset, unescaped plain text).
	private func stampedRuns(in html: String) -> [(offset: Int, text: String)] {
		let regex = try! NSRegularExpression(pattern: #"<span data-s="(\d+)">(.*?)</span>"#, options: [.dotMatchesLineSeparators])
		let ns = html as NSString
		return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { match in
			let offset = Int(ns.substring(with: match.range(at: 1)))!
			let inner = ns.substring(with: match.range(at: 2))
				.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
				.replacingOccurrences(of: "&lt;", with: "<")
				.replacingOccurrences(of: "&gt;", with: ">")
				.replacingOccurrences(of: "&quot;", with: "\"")
				.replacingOccurrences(of: "&#39;", with: "'")
				.replacingOccurrences(of: "&amp;", with: "&")
			return (offset, inner)
		}
	}

	/// Every stamped run's text must equal the source at its stamped offset.
	private func expectStampsVerbatim(in source: String, minimumRuns: Int = 1,
									  sourceLocation: Testing.SourceLocation = #_sourceLocation) {
		let html = MarkdownHTMLRenderer.renderDocument(markdown: source, includeSourceOffsets: true)
		let runs = stampedRuns(in: html)
		#expect(runs.count >= minimumRuns, "expected at least \(minimumRuns) stamped runs", sourceLocation: sourceLocation)
		let ns = source as NSString
		for run in runs {
			let length = (run.text as NSString).length
			guard run.offset >= 0, run.offset + length <= ns.length else {
				Issue.record("stamp \(run.offset) len \(length) outside source (len \(ns.length))", sourceLocation: sourceLocation)
				continue
			}
			let actual = ns.substring(with: NSRange(location: run.offset, length: length))
			#expect(actual == run.text, "stamp \(run.offset) covers \"\(actual)\", run shows \"\(run.text)\"", sourceLocation: sourceLocation)
		}
	}

	@Test func plainAndStyledRunsStampVerbatim() {
		expectStampsVerbatim(in: "Hello **bold** tail and *emph* end", minimumRuns: 4)
	}

	@Test func typographyCharactersStayVerbatimWhenEditable() {
		// Smart quotes/dashes/ellipsis/emoji substitutions are skipped for
		// editable rendering, so these runs stamp and match the file's text.
		expectStampsVerbatim(in: "He said \"hi\" -- twice... :smile: done")
	}

	@Test func linkifiedRunsKeepCorrectStampsAfterSplit() {
		// Bare-URL linkify splits a stamped run; the fragments after the URL
		// must be re-stamped past the text their predecessors consumed.
		expectStampsVerbatim(in: "before www.example.com after and https://foo.bar/x tail", minimumRuns: 3)
	}

	@Test func multiLineAndHeadingRunsStampVerbatim() {
		expectStampsVerbatim(in: "# Title\n\nFirst paragraph line\nsecond line\n\n- item one\n- item two", minimumRuns: 4)
	}

	@Test func lazyListContinuationAfterInlineHTMLStampsVerbatim() {
		// swift-markdown reports these continuation lines at the list content's
		// virtual indentation. Stamps must recover the actual source column.
		expectStampsVerbatim(in: """
		2. **Timeline** - /app/lib/timeline<br />
		This view is displayed after the break. <br/>
		When an event is in view, show the ArticlePage.
		""", minimumRuns: 3)
	}

	@Test func frontmatterShiftsStampsToFullSource() {
		expectStampsVerbatim(in: "---\ntitle: Test\n---\n\nBody paragraph here")
	}

	@Test func entityRunsGoUnstampedInsteadOfDrifting() {
		// "&amp;" renders as one character but occupies five in the source; a
		// linear stamp there would drift every later position in the run.
		expectStampsVerbatim(in: "a &amp; b, then &lt;tag&gt; end", minimumRuns: 0)
	}

	@Test func linkTextRunsStampVerbatim() {
		expectStampsVerbatim(in: "see [the docs](https://example.com/d) for more", minimumRuns: 2)
	}

	@Test func tableCellRunsStampVerbatim() {
		// Cells run through the same stamped inline renderer as paragraphs;
		// their runs must address the text between the pipes, styled cells
		// included. (The styled view currently keeps tables contentEditable
		// = false — these stamps are what cell editing would splice through.)
		expectStampsVerbatim(
			in: "| Name | Age |\n| --- | --- |\n| Alice | 30 |\n| **Bob** | 41 |",
			minimumRuns: 6)
	}

	@Test func fencedCodeContentStampsVerbatim() {
		expectStampsVerbatim(
			in: "before\n\n```swift\nlet value = 42\nprint(value)\n```\n\nafter",
			minimumRuns: 3)
	}

	@Test func sampleReleaseNotesDocumentStampsVerbatim() throws {
		// A real document: curly quotes and em dashes as literal source
		// characters, bold runs mid-paragraph, and an emoji (surrogate pair).
		let fixture = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.appendingPathComponent("Fixtures/SuperDuper-0.6.0.md")
		let source = try String(contentsOf: fixture, encoding: .utf8)
		expectStampsVerbatim(in: source, minimumRuns: 20)
	}
}
