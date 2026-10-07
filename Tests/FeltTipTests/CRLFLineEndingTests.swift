//
//  CRLFLineEndingTests.swift
//  FeltTip
//
//  Passes that rebuild the document text must not change its line endings.
//  Splitting on `.newlines` and rejoining with "\n" turned every CRLF into a
//  blank line, and in the editable view misaligned every source stamp after
//  the first such line.
//

import Foundation
import Testing
@testable import FeltTip

@Suite struct CRLFLineEndingTests {
	private func crlfCount(_ s: String) -> Int { s.components(separatedBy: "\r\n").count - 1 }

	@Test func definitionListKeepsSurroundingCRLF() {
		let source = "Intro\r\n\r\nTerm\r\n: Definition\r\n\r\nAfter\r\n"
		let output = DefinitionListProcessor.process(source)
		#expect(output.contains("<dt>Term</dt>"))
		#expect(output.contains("<dd>Definition</dd>"))
		#expect(output.hasPrefix("Intro\r\n\r\n"))
		#expect(output.hasSuffix("\r\nAfter\r\n"))
		#expect(!output.contains("\n\n\n"))
	}

	@Test func definitionListSourceGroupsAgreeWithProcessOnCRLF() {
		let source = "Term\r\n: Definition\r\n"
		let groups = DefinitionListProcessor.sourceGroups(in: source, baseOffset: 0)
		#expect(groups.count == 1)
		#expect(groups.first?.first?.term == "Term")
		#expect(groups.first?.first?.definitions == ["Definition"])
		#expect(groups.first?.first?.definitionStarts == [(source as NSString).range(of: "Definition").location])
	}

	@Test func citationRenderingKeepsCRLF() {
		let source = "See [@key].\r\n\r\n[@key]: A reference\r\n"
		let citations = Citation.parse(from: source)
		let output = Citation.renderableContent(from: source, citations: citations)
		#expect(citations.count == 1)
		#expect(output.hasPrefix("See [¹](citation://key).\r\n"))
		#expect(!output.contains("\n\n\n"))
	}

	@Test func footnoteRenderingKeepsCRLF() {
		let source = "Text[^1] here.\r\n\r\n[^1]: Note\r\n"
		let notes = MarkdownFootnote.parse(from: source)
		let output = MarkdownFootnote.renderableContent(from: source, footnotes: notes)
		#expect(notes.count == 1)
		#expect(output.hasPrefix("Text[¹](footnote://1) here.\r\n"))
		#expect(MarkdownFootnote.cleanedForRendering(from: source).hasPrefix("Text here.\r\n"))
	}

	@Test func frontmatterBodyIsAByteExactSuffixOfACRLFSource() {
		let source = "---\r\ntitle: Hello\r\n---\r\nBody text\r\n"
		let blocks = MarkdownBlockParser.parse(source, trackSourceOffsets: true)
		guard case .frontmatter(let pairs, _)? = blocks.first else {
			Issue.record("frontmatter block missing: \(blocks)"); return
		}
		#expect(pairs.first?.key == "title")
		#expect(pairs.first?.value == "Hello")
		guard case .paragraph(let content, _, _)? = blocks.dropFirst().first else {
			Issue.record("paragraph missing: \(blocks)"); return
		}
		let stamp = content.runs.first?.markdownSourceOffset
		#expect(stamp == (source as NSString).range(of: "Body text").location)
		#expect(String(content.characters) == "Body text")
	}

	@Test func preprocessorPreservesCRLFCount() {
		let source = "# Title\r\n\r\nTerm\r\n: Def\r\n\r\nSee [@k] and [^n].\r\n\r\n[@k]: Ref\r\n[^n]: Note\r\n\r\nEnd (c)\r\n"
		let output = MarkdownPreprocessor.process(source)
		// Definition and footnote/citation definition lines are consumed and a
		// footnote section is appended; every other line keeps its ending.
		#expect(output.contains("# Title\r\n\r\n"))
		#expect(output.contains("End ©\r\n"))
		#expect(!output.hasPrefix("# Title\n\n"))
	}
}
