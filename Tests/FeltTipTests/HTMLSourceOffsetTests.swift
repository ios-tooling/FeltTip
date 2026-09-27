//
//  HTMLSourceOffsetTests.swift
//  FeltTipTests
//
//  The editable webview maps caret positions back to the Markdown source via
//  `data-s` offsets emitted on inline runs. Export output must stay clean.
//

import Testing
@testable import FeltTip

@Suite struct HTMLSourceOffsetTests {
	@Test func emitsRunOffsetsWhenRequested() {
		// "hello **bold** world": 'hello ' at 0, 'bold' at 8 (after `**`), ' world' at 14.
		let html = MarkdownHTMLRenderer.renderDocument(markdown: "hello **bold** world", includeSourceOffsets: true)
		#expect(html.contains("data-s=\"0\""))
		#expect(html.contains("data-s=\"8\""))
		#expect(html.contains("data-s=\"14\""))
	}

	@Test func exportOutputHasNoOffsets() {
		let html = MarkdownHTMLRenderer.renderDocument(markdown: "hello **bold** world")
		#expect(!html.contains("data-s="))
	}
}
