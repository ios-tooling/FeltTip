//
//  HTMLPassthroughSanitizerTests.swift
//  FeltTipTests
//
//  A markdown document is untrusted input, and its HTML blocks reach the page
//  the edit bridge lives in. These are the vectors that must not survive, and —
//  just as important — the ordinary formatting HTML that must survive
//  untouched, byte for byte.
//

import Foundation
import Testing
@testable import FeltTip

@Suite struct HTMLPassthroughSanitizerTests {
	private func clean(_ html: String) -> String { HTMLPassthroughSanitizer.sanitize(html) }

	// MARK: Script execution

	@Test func scriptElementsGoWithTheirContents() {
		#expect(clean("<script>alert(1)</script>") == "")
		#expect(clean("before<script>alert(1)</script>after") == "beforeafter")
		#expect(clean("<script src=\"https://evil.example/x.js\"></script>") == "")
	}

	@Test func scriptDetectionIsCaseAndWhitespaceInsensitive() {
		#expect(clean("<SCRIPT>alert(1)</SCRIPT>") == "")
		#expect(clean("<script >alert(1)</script >") == "")
		#expect(clean("<ScRiPt type=\"text/javascript\">alert(1)</script>") == "")
	}

	@Test func anUnclosedScriptTakesTheRestOfTheBlock() {
		// Better to lose the tail of one HTML block than to leave a live script.
		#expect(clean("<p>ok</p><script>alert(1)") == "<p>ok</p>")
	}

	@Test func scriptInsideOtherMarkupIsStillRemoved() {
		#expect(clean("<div><script>alert(1)</script>text</div>") == "<div>text</div>")
		#expect(clean("<svg><script>alert(1)</script><circle r=\"5\" /></svg>")
			== "<svg><circle r=\"5\" /></svg>")
	}

	// MARK: Event handlers

	@Test func eventHandlersAreStrippedButTheElementStays() {
		#expect(clean("<img src=\"a.png\" onerror=\"alert(1)\">") == "<img src=\"a.png\">")
		#expect(clean("<div onclick=\"alert(1)\">text</div>") == "<div>text</div>")
		#expect(clean("<p ONMOUSEOVER=alert(1)>hi</p>") == "<p>hi</p>")
		#expect(clean("<body onload=\"x\">") == "<body>")
	}

	@Test func handlersWithUnusualSpacingAndQuotingAreStillFound() {
		#expect(clean("<img src=x onerror = 'alert(1)' >") == "<img src=\"x\">")
		#expect(clean("<img\n  src=\"a.png\"\n  onerror=\"alert(1)\">") == "<img src=\"a.png\">")
	}

	@Test func smilAnimationCannotInstallAHandler() {
		#expect(clean("<set attributeName=\"onload\" to=\"alert(1)\" />") == "")
	}

	@Test func smilCannotMutateLinksIntoExecutableURLs() {
		#expect(clean("<svg><a><set attributeName=\"href\" to=\"javascript:alert(1)\"/><text>x</text></a></svg>")
			== "<svg><a><text>x</text></a></svg>")
		#expect(clean("<animate attributeName=\"href\" values=\"https://safe;javascript:alert(1)\"/>") == "")
	}

	// MARK: URL schemes

	@Test func scriptURLsAreDropped() {
		#expect(clean("<a href=\"javascript:alert(1)\">x</a>") == "<a>x</a>")
		#expect(clean("<a href=\"JaVaScRiPt:alert(1)\">x</a>") == "<a>x</a>")
		#expect(clean("<a href=\"vbscript:x\">x</a>") == "<a>x</a>")
		#expect(clean("<form action=\"javascript:x\"><input></form>") == "")
		#expect(clean("<form action=\"https://example.com\"><button>Continue</button></form>") == "Continue")
	}

	@Test func encodedScriptURLsAreDroppedToo() {
		#expect(clean("<a href=\"java&#115;cript:alert(1)\">x</a>") == "<a>x</a>")
		#expect(clean("<a href=\"&#x6a;avascript:alert(1)\">x</a>") == "<a>x</a>")
		#expect(clean("<a href=\"java\tscript:alert(1)\">x</a>") == "<a>x</a>")
	}

	@Test func ordinaryAndRelativeURLsSurvive() {
		#expect(clean("<a href=\"https://example.com\">x</a>") == "<a href=\"https://example.com\">x</a>")
		#expect(clean("<a href=\"mailto:me@example.com\">x</a>") == "<a href=\"mailto:me@example.com\">x</a>")
		#expect(clean("<img src=\"images/local.png\">") == "<img src=\"images/local.png\">")
		#expect(clean("<a href=\"#section\">x</a>") == "<a href=\"#section\">x</a>")
		#expect(clean("<a href=\"//example.com/x\">x</a>") == "<a href=\"//example.com/x\">x</a>")
		#expect(clean("<img src=\"markerlocalres://res/a.png\">") == "<img src=\"markerlocalres://res/a.png\">")
	}

	@Test func dataURLsAreImagesOnly() {
		let image = "<img src=\"data:image/png;base64,iVBORw0KGgo=\">"
		#expect(clean(image) == image)
		#expect(clean("<a href=\"data:text/html,<script>alert(1)</script>\">x</a>") == "<a>x</a>")
		// SVG data URLs carry script; not worth the risk for an inline image.
		#expect(clean("<img src=\"data:image/svg+xml;base64,PHN2Zz4=\">") == "<img>")
	}

	@Test func srcdocIsDropped() {
		#expect(clean("<div srcdoc=\"<script>alert(1)</script>\">x</div>") == "<div>x</div>")
	}

	@Test func hyperlinkAuditingIsDropped() {
		#expect(clean("<a href=\"https://safe.example\" ping=\"https://tracker.example/p\">x</a>")
			== "<a href=\"https://safe.example\">x</a>")
		#expect(clean("<a PING='//tracker.example/p' href='/local'>x</a>")
			== "<a href=\"/local\">x</a>")
	}

	// MARK: Document-level elements

	@Test func documentReloadingElementsAreDropped() {
		#expect(clean("<base href=\"https://evil.example/\">") == "")
		#expect(clean("<meta http-equiv=\"refresh\" content=\"0;url=https://evil.example\">") == "")
		#expect(clean("<link rel=\"stylesheet\" href=\"https://evil.example/x.css\">") == "")
		#expect(clean("<style>@import url(https://evil.example/x.css);</style>") == "")
		#expect(clean("<div style=\"background:url(https://evil.example/pixel)\">x</div>") == "<div>x</div>")
	}

	@Test func embeddedDocumentsAreDropped() {
		#expect(clean("<iframe src=\"https://evil.example\"></iframe>") == "")
		#expect(clean("<object data=\"x.swf\">fallback</object>") == "")
		#expect(clean("<embed src=\"x.swf\">") == "")
		#expect(clean("text<iframe srcdoc=\"<script>alert(1)</script>\"></iframe>more") == "textmore")
	}

	// MARK: Everything else survives untouched

	@Test func cleanMarkupIsPassedThroughByteForByte() {
		let samples = [
			"<div class=\"note\">text</div>",
			"<details><summary>More</summary><p>body</p></details>",
			"<table><tr><td align=center>a</td></tr></table>",
			"<img src=\"a.png\" width=100 height='50' alt=\"an image\">",
			"<span data-thing='x' title=\"a > b\">y</span>",
			"<kbd>⌘</kbd><sup>1</sup><sub>2</sub>",
			"<br>",
			"<hr />",
			"<p>unquoted=values and text</p>",
			"<!-- a comment -->",
			"<div>\n\t<p>indented</p>\n</div>",
		]
		for sample in samples {
			#expect(clean(sample) == sample, "changed: \(sample)")
		}
	}

	@Test func textIsLeftAloneAndStrayAnglesAreEscaped() {
		#expect(clean("plain text") == "plain text")
		#expect(clean("a < b and c > d") == "a &lt; b and c > d")
		#expect(clean("5 < 6") == "5 &lt; 6")
	}

	@Test func quotesInKeptValuesStayValidWhenATagIsRewritten() {
		// The tag has to be rebuilt (the handler goes), so its remaining values
		// are re-quoted — and must stay parseable.
		#expect(clean("<div title='a \"quoted\" thing' onclick=\"x\">t</div>")
			== "<div title=\"a &quot;quoted&quot; thing\">t</div>")
	}

	@Test func ampersandsInRewrittenValuesAreEncodedOnce() {
		#expect(clean("<a href=\"https://x.example/?a=1&amp;b=2\" onclick=\"y\">t</a>")
			== "<a href=\"https://x.example/?a=1&amp;b=2\">t</a>")
	}

	// MARK: Through the renderer

	@Test func renderedDocumentsCarryNoScript() {
		let markdown = """
			# Doc

			<script>window.__pwned = 1</script>

			text <span onmouseover="alert(1)">hover</span>

			<iframe src="https://evil.example"></iframe>
			"""
		let html = MarkdownHTMLRenderer.renderBodyFragment(markdown: markdown)
		#expect(!html.lowercased().contains("<script"))
		#expect(!html.lowercased().contains("<iframe"))
		#expect(!html.lowercased().contains("onmouseover"))
		#expect(html.contains("Doc"))
	}

	@Test func aScriptInADocumentDoesNotSurviveIntoTheFullPage() async {
		let html = await MarkdownRenderService.shared.documentHTML(
			markdown: "text\n\n<script>window.__pwned = 1</script>\n",
			theme: .default, fontSize: 14, includeSourceOffsets: true,
			interactiveCheckboxes: false, embedMermaidEngine: false).html
		// The page's own scripts are added by the host, not by the document.
		#expect(!html.contains("__pwned"))
	}
}
