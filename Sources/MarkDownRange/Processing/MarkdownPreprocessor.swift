//
//  MarkdownPreprocessor.swift
//  MarkDownRange
//

import Foundation

/// Centralizes the order in which markdown text passes through our pre-parse
/// processors. Used by `MarkdownBlockParser` for its non-preprocessed path and
/// kept in step with the manual preprocessing in `FormattedMarkdownScreen`,
/// which has to invoke the processors directly so it can keep references to
/// the parsed citations and footnotes for side panels.
public enum MarkdownPreprocessor {
	public static func process(_ body: String) -> String {
		let citations = Citation.parse(from: body)
		let withCitations = Citation.renderableContent(from: body, citations: citations)
		let footnotes = MarkdownFootnote.parse(from: withCitations)
		let withFootnotes = MarkdownFootnote.renderableContent(from: withCitations, footnotes: footnotes)
		let withAppendedNotes = appendFootnoteSection(to: withFootnotes, footnotes: footnotes)
		return common(after: withAppendedNotes)
	}

	/// Appends footnote bodies as a trailing section so renderers that don't
	/// have their own footnote panel (the native `MarkdownTextView` and the
	/// QuickLook preview) still show the actual note text — without this the
	/// superscript reference is the only thing the user ever sees.
	/// `FormattedMarkdownScreen` skips this path: it parses footnotes itself
	/// and surfaces them in a dedicated bottom panel, so duplicating them in
	/// the body would just create noise.
	///
	/// The opening superscript uses the `footnote-anchor://id` scheme so the
	/// click handler can scroll the reference *to* it, and a trailing
	/// `↩` link uses `footnote-back://id` to scroll back to the reference.
	private static func appendFootnoteSection(to body: String, footnotes: [MarkdownFootnote]) -> String {
		guard !footnotes.isEmpty else { return body }
		let entries = footnotes
			.sorted { $0.displayIndex < $1.displayIndex }
			.map { footnote in
				let sup = MarkdownFootnote.superscript(for: footnote.displayIndex)
				return "[\(sup)](footnote-anchor://\(footnote.id)) \(footnote.content) [↩](footnote-back://\(footnote.id))"
			}
			.joined(separator: "\n\n")
		return body + "\n\n---\n\n" + entries
	}

	/// Step shared with `FormattedMarkdownScreen`, which parses citations and
	/// footnotes itself so it can keep handles on them.
	public static func common(after withFootnotes: String) -> String {
		let withAbbreviations = AbbreviationProcessor.process(withFootnotes)
		let withContainers = CustomContainerProcessor.process(withAbbreviations)
		let withSuperSub = SuperSubProcessor.process(withContainers)
		let withInserted = InsertedTextProcessor.process(withSuperSub)
		let withEmoticons = EmoticonShortcodes.process(withInserted)
		let withQuotes = SmartQuotes.process(withEmoticons)
		let withTypography = SmartTypography.process(withQuotes)
		return WikilinkProcessor.process(
			DefinitionListProcessor.process(
				HighlightSyntax.process(
					EmojiShortcodes.process(withTypography)
				)
			)
		)
	}
}
