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
	public static func process(_ body: String, options: MarkdownOptions = .default, preservingSourceText: Bool = false) -> String {
		let citations = Citation.parse(from: body)
		let withCitations = Citation.renderableContent(from: body, citations: citations)
		let footnotes = MarkdownFootnote.parse(from: withCitations)
		let withFootnotes = MarkdownFootnote.renderableContent(from: withCitations, footnotes: footnotes)
		let withAppendedNotes = appendFootnoteSection(to: withFootnotes, footnotes: footnotes)
		return common(after: withAppendedNotes, options: options, preservingSourceText: preservingSourceText)
	}

	/// Preprocesses `body` and also returns a map from each UTF-16 offset in the
	/// processed output back to its UTF-16 offset in `body`. The editable
	/// renderers use this so styled-text edits map to the original source even
	/// though the rendered text reflects preprocessing.
	///
	/// Editable rendering preserves the source's own characters: the cosmetic
	/// substitutions (smart quotes, typography, emoji/emoticon shortcodes) are
	/// skipped so the text a run shows is the text the file contains — the
	/// editors rely on rendered run text mapping 1:1 onto the source when
	/// translating caret positions into source offsets.
	///
	/// The map is derived by diffing input against output rather than
	/// instrumenting each pass: it covers every remaining pass for free, and
	/// runs whose mapping isn't 1:1 go unstamped (see
	/// `SourceOffsetConverter.verbatimUTF16Offset`), so the editors veto edits
	/// there instead of corrupting the file.
	public static func processTrackingOffsets(_ body: String, options: MarkdownOptions = .default) -> (processed: String, map: [Int]) {
		let processed = process(body, options: options, preservingSourceText: true)
		return (processed, offsetMap(from: body, to: processed))
	}

	/// For each UTF-16 position in `processed`, the UTF-16 position in `source`
	/// it originated from. Surviving characters map to themselves; synthesized
	/// characters (inserted markup) map to their nearest surviving neighbor.
	static func offsetMap(from source: String, to processed: String) -> [Int] {
		let src = Array(source.utf16)
		let dst = Array(processed.utf16)
		if src == dst { return Array(0..<dst.count) }
		// Trim the common prefix and suffix before diffing: Myers cost grows
		// with input length as well as edit distance, and preprocessing
		// usually rewrites a small slice of a large document.
		var prefix = 0
		while prefix < src.count, prefix < dst.count, src[prefix] == dst[prefix] { prefix += 1 }
		var suffix = 0
		while suffix < src.count - prefix, suffix < dst.count - prefix,
		      src[src.count - 1 - suffix] == dst[dst.count - 1 - suffix] { suffix += 1 }
		let srcMiddle = Array(src[prefix..<(src.count - suffix)])
		let dstMiddle = Array(dst[prefix..<(dst.count - suffix)])
		let diff = dstMiddle.difference(from: srcMiddle)
		// Transform an identity array of source offsets exactly as the diff
		// transforms the middle of `src` into the middle of `dst`: drop
		// removed positions (descending so offsets stay valid), then give
		// each inserted position its nearest surviving neighbor's offset.
		var offsets = Array(prefix..<(src.count - suffix))
		for change in diff.removals.reversed() {
			if case let .remove(offset, _, _) = change { offsets.remove(at: offset) }
		}
		for change in diff.insertions {
			if case let .insert(offset, _, _) = change {
				let neighbor = offset > 0 ? offsets[offset - 1]
					: (offset < offsets.count ? offsets[offset] : (prefix > 0 ? prefix - 1 : 0))
				offsets.insert(neighbor, at: offset)
			}
		}
		let shift = src.count - dst.count
		return Array(0..<prefix) + offsets + (dst.count - suffix..<dst.count).map { $0 + shift }
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
	/// footnotes itself so it can keep handles on them. `preservingSourceText`
	/// (editable rendering) skips the cosmetic character substitutions so
	/// rendered run text stays byte-for-byte the source's.
	public static func common(after withFootnotes: String, options: MarkdownOptions = .default, preservingSourceText: Bool = false) -> String {
		func timed<T>(_ label: String, _ work: () -> T) -> T {
			let t = CFAbsoluteTimeGetCurrent()
			let result = work()
			Self.recordTiming(label, ms: (CFAbsoluteTimeGetCurrent() - t) * 1000)
			return result
		}
		let withAbbreviations = timed("Abbreviation") { AbbreviationProcessor.process(withFootnotes) }
		let withContainers = timed("CustomContainer") { CustomContainerProcessor.process(withAbbreviations) }
		// All seven of the per-line processors run inside a single split-
		// iterate-join pass — we used to do ten separate ones, which cost
		// ~80 ms of pure split/join on a 200-section document. Order is
		// preserved against the previous chain (Heading → SuperSub → Inserted
		// → Emoticon → SmartQuotes → SmartTypography → Highlight). HeadingSpace
		// used to run before Abbreviation/CustomContainer; neither of those
		// inspects heading syntax so the move is behaviour-preserving.
		let withLinePass = timed("LinePass") { mergedLinePass(withContainers, options: options, preservingSourceText: preservingSourceText) }
		let withEmoji = preservingSourceText ? withLinePass : timed("Emoji") { EmojiShortcodes.process(withLinePass) }
		let withDefList = timed("DefinitionList") { DefinitionListProcessor.process(withEmoji) }
		let withWikilinks = timed("Wikilink") { WikilinkProcessor.process(withDefList) }
		return withWikilinks
	}

	/// Runs the seven per-line preprocessors in a single shared loop. Each
	/// processor's `applyLine` bakes in its own per-line fast-fail and any
	/// special skip conditions (e.g. SmartQuotes skipping link reference
	/// definitions), so we don't need to know per-processor specifics here.
	private static func mergedLinePass(_ text: String, options: MarkdownOptions, preservingSourceText: Bool) -> String {
		var output: [String] = []
		var inFence = false
		let lines = text.components(separatedBy: "\n")
		output.reserveCapacity(lines.count)
		let injectHeadingSpace = !options.headingsRequireSpaceAfterHash
		for line in lines {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
				inFence.toggle()
				output.append(line); continue
			}
			if inFence { output.append(line); continue }
			var processed = line
			if injectHeadingSpace { processed = HeadingSpaceInjector.applyLine(processed) }
			processed = SuperSubProcessor.applyLine(processed)
			processed = InsertedTextProcessor.applyLine(processed)
			if !preservingSourceText {
				processed = EmoticonShortcodes.applyLine(processed)
				processed = SmartQuotes.applyLine(processed)
				processed = SmartTypography.applyLine(processed)
			}
			processed = HighlightSyntax.applyLine(processed)
			output.append(processed)
		}
		return output.joined(separator: "\n")
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
