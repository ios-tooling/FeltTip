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
	public static func process(_ body: String, options: MarkdownOptions = .default) -> String {
		let citations = Citation.parse(from: body)
		let withCitations = Citation.renderableContent(from: body, citations: citations)
		let footnotes = MarkdownFootnote.parse(from: withCitations)
		let withFootnotes = MarkdownFootnote.renderableContent(from: withCitations, footnotes: footnotes)
		let withAppendedNotes = appendFootnoteSection(to: withFootnotes, footnotes: footnotes)
		return common(after: withAppendedNotes, options: options)
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
	public static func common(after withFootnotes: String, options: MarkdownOptions = .default) -> String {
		func timed<T>(_ label: String, _ work: () -> T) -> T {
			let t = CFAbsoluteTimeGetCurrent()
			let result = work()
			Self.recordTiming(label, ms: (CFAbsoluteTimeGetCurrent() - t) * 1000)
			return result
		}
		let withHeadings = options.headingsRequireSpaceAfterHash
			? withFootnotes
			: timed("HeadingSpace") { HeadingSpaceInjector.process(withFootnotes) }
		let withAbbreviations = timed("Abbreviation") { AbbreviationProcessor.process(withHeadings) }
		let withContainers = timed("CustomContainer") { CustomContainerProcessor.process(withAbbreviations) }
		let withSuperSub = timed("SuperSub") { SuperSubProcessor.process(withContainers) }
		let withInserted = timed("Inserted") { InsertedTextProcessor.process(withSuperSub) }
		let withEmoticons = timed("Emoticon") { EmoticonShortcodes.process(withInserted) }
		let withQuotes = timed("SmartQuotes") { SmartQuotes.process(withEmoticons) }
		let withTypography = timed("SmartTypography") { SmartTypography.process(withQuotes) }
		let withEmoji = timed("Emoji") { EmojiShortcodes.process(withTypography) }
		let withHighlight = timed("Highlight") { HighlightSyntax.process(withEmoji) }
		let withDefList = timed("DefinitionList") { DefinitionListProcessor.process(withHighlight) }
		let withWikilinks = timed("Wikilink") { WikilinkProcessor.process(withDefList) }
		return withWikilinks
	}

	/// Per-processor timings (ms) accumulated across a single preprocess
	/// pass. Reset by the host between runs. Benchmarking only.
	///
	/// Tests run in parallel and used to crash the runner here because two
	/// concurrent `process` calls would mutate the dict from different
	/// threads simultaneously. The lock makes the bookkeeping correct (or
	/// at least non-crashing) under parallel access — values can still
	/// interleave between concurrent parses, which is fine for benchmarking
	/// where only one parse runs at a time.
	private static let recordedLock = NSLock()
	public static var recordedTimings: [String: Double] {
		get {
			recordedLock.lock(); defer { recordedLock.unlock() }
			return _recordedTimings
		}
		set {
			recordedLock.lock(); defer { recordedLock.unlock() }
			_recordedTimings = newValue
		}
	}
	nonisolated(unsafe) private static var _recordedTimings: [String: Double] = [:]

	fileprivate static func recordTiming(_ label: String, ms: Double) {
		recordedLock.lock(); defer { recordedLock.unlock() }
		_recordedTimings[label, default: 0] += ms
	}
}
