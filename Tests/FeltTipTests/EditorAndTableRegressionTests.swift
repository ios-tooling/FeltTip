import Foundation
import Testing
@testable import FeltTip

struct EditorAndTableRegressionTests {
 @Test func rowHeadersPreserved() {
  let html = MarkdownHTMLRenderer.renderBodyFragment(markdown: "<table><tr><th>Name</th><td>Alice</td></tr><tr><th>Role</th><td>Author</td></tr></table>")
  #expect(html.contains("Alice"))
  #expect(html.contains("Role"))
 }
 @Test func tableTextAroundLinksPreserved() {
  let html = MarkdownHTMLRenderer.renderBodyFragment(markdown: "<table><tr><td>Read <a href=\"https://example.com\">the guide</a> first</td></tr></table>")
  #expect(html.contains("Read"))
  #expect(html.contains("first"))
 }
 @Test func dataAttributesDoNotOverrideDestinations() {
  let html = MarkdownHTMLRenderer.renderBodyFragment(markdown: "<p><a href=\"https://correct.test\" data-href=\"https://wrong.test\">Link</a><img data-src=\"wrong.png\" src=\"correct.png\"></p>")
  #expect(html.contains("href=\"https://correct.test\""))
  #expect(html.contains("src=\"correct.png\""))
 }
 @Test func escapedBackticksSurviveCodeToggle() throws {
  let source = "\\`hello`"
  let change = try #require(MarkdownInlineCodeToggle.change(in: source, selection: NSRange(location: 2, length: 5)))
  let updated = (source as NSString).replacingCharacters(in: change.range, with: change.replacement)
  #expect(updated.hasPrefix("\\`"))
  #expect(MarkdownHTMLRenderer.renderBodyFragment(markdown: updated).contains("<code>"))
 }
}

extension EditorAndTableRegressionTests {
 @Test(arguments: [
  "<img data-src='wrong.png' src='right.png'>",
  "<img src='right.png' data-src='wrong.png'>",
  "<img title=\"a src='wrong.png'\" SRC = 'right.png'>",
  "<img src = right.png data-src=wrong.png>"
 ])
 func imageAttributeNamesAreExact(tag: String) {
  #expect(HTMLAttributeParser.extractImage(from: tag)?.src == "right.png")
  #expect(ImageRegions.collect(in: tag).first?.src == "right.png")
 }
 @Test func missingRealAttributesAreNotInvented() {
  #expect(HTMLAttributeParser.extractImage(from: "<img data-src='wrong.png'>") == nil)
  #expect(HTMLAttributeParser.extractLink(from: "<a data-href='https://wrong.test'>text</a>") == nil)
  #expect(HTMLAttributeParser.extractAttribute("width", from: "<img data-width='200'>") == nil)
 }
 @Test func tableLinksPreserveTextTraitsAndOrder() throws {
  let parsed = try #require(HTMLTableParser.parse(html: "<table><tr><td><b>Read</b> <a href='https://a.test'>A &amp; B</a>, then <a href='https://b.test'>C</a>.</td></tr></table>"))
  let cell = try #require(parsed.rows.first?.first)
  guard case .text(let text, _) = cell else { Issue.record("Expected text"); return }
  #expect(String(text.characters) == "Read A & B, then C.")
  #expect(text.runs.contains { $0.link?.absoluteString == "https://a.test" })
  #expect(text.runs.contains { $0.link?.absoluteString == "https://b.test" })
  #expect(text.runs.contains { ($0.inlineFontTraits ?? []).contains(.bold) })
 }
 @Test func mixedCellsStayInBodyRows() throws {
  let parsed = try #require(HTMLTableParser.parse(html: "<table><tr><th>Name</th><td>Alice</td></tr><tr><th>Role</th><td>Author</td></tr></table>"))
  #expect(parsed.header.isEmpty)
  #expect(parsed.rows.map { $0.map { String($0.characters) } } == [["Name", "Alice"], ["Role", "Author"]])
 }
 @Test(arguments: ["hello", "world"])
 func partialSelectionWithEscapedDelimiter(selected: String) throws {
  let source = "\\`hello world`"
  let change = try #require(MarkdownInlineCodeToggle.change(in: source, selection: (source as NSString).range(of: selected)))
  let updated = (source as NSString).replacingCharacters(in: change.range, with: change.replacement)
  let rendered = MarkdownHTMLRenderer.renderBodyFragment(markdown: updated)
  #expect(rendered.contains("<code>" + selected + "</code>"))
  #expect(updated.hasPrefix("\\`"))
 }
 @Test func evenBackslashesStillAllowUnwrap() throws {
  let source = "\\\\`hello`"
  let change = try #require(MarkdownInlineCodeToggle.change(in: source, selection: (source as NSString).range(of: "hello")))
  #expect((source as NSString).replacingCharacters(in: change.range, with: change.replacement) == "\\\\hello")
 }
}

extension EditorAndTableRegressionTests {
 @Test func adjacentRealCodeIsNotEscaped() {
  let source = "hello`world`"
  #expect(MarkdownInlineCodeToggle.change(in: source, selection: NSRange(location: 0, length: 5)) == nil)
 }
}
