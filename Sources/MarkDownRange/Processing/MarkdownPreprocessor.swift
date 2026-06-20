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

	/// Preprocesses `body` and also returns a map from each UTF-16 offset in the
	/// processed output back to its UTF-16 offset in `body`. The editable
	/// renderers use this so styled-text edits map to the original source even
	/// though the rendered text reflects preprocessing (highlight, smart quotes,
	/// emoji shortcodes, …).
	///
	/// The map is derived by diffing input against output rather than
	/// instrumenting each pass: it covers every pass for free, and it's safe
	/// because the editor verifies the source slice before splicing — an
	/// imperfect mapping resyncs the view instead of corrupting the file.
	public static func processTrackingOffsets(_ body: String, options: MarkdownOptions = .default) -> (processed: String, map: [Int]) {
		let processed = process(body, options: options)
		return (processed, offsetMap(from: body, to: processed))
	}

	/// For each UTF-16 position in `processed`, the UTF-16 position in `source`
	/// it originated from. Surviving characters map to themselves; synthesized
	/// characters (inserted markup) map to their nearest surviving neighbor.
	static func offsetMap(from source: String, to processed: String) -> [Int] {
		let src = Array(source.utf16)
		let dst = Array(processed.utf16)
		if src == dst { return Array(0..<dst.count) }
		let diff = dst.difference(from: src)
		// Transform an identity array of source offsets exactly as the diff
		// transforms `src` into `dst`: drop removed positions (descending so
		// offsets stay valid), then give each inserted position its nearest
		// surviving neighbor's source offset.
		var offsets = Array(0..<src.count)
		for change in diff.removals.reversed() {
			if case let .remove(offset, _, _) = change { offsets.remove(at: offset) }
		}
		for change in diff.insertions {
			if case let .insert(offset, _, _) = change {
				let neighbor = offset > 0 ? offsets[offset - 1]
					: (offset < offsets.count ? offsets[offset] : (offsets.last ?? 0))
				offsets.insert(neighbor, at: offset)
			}
		}
		return offsets
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
		let withAbbreviations = timed("Abbreviation") { AbbreviationProcessor.process(withFootnotes) }
		let withContainers = timed("CustomContainer") { CustomContainerProcessor.process(withAbbreviations) }
		// All seven of the per-line processors run inside a single split-
		// iterate-join pass — we used to do ten separate ones, which cost
		// ~80 ms of pure split/join on a 200-section document. Order is
		// preserved against the previous chain (Heading → SuperSub → Inserted
		// → Emoticon → SmartQuotes → SmartTypography → Highlight). HeadingSpace
		// used to run before Abbreviation/CustomContainer; neither of those
		// inspects heading syntax so the move is behaviour-preserving.
		let withLinePass = timed("LinePass") { mergedLinePass(withContainers, options: options) }
		let withEmoji = timed("Emoji") { EmojiShortcodes.process(withLinePass) }
		let withDefList = timed("DefinitionList") { DefinitionListProcessor.process(withEmoji) }
		let withWikilinks = timed("Wikilink") { WikilinkProcessor.process(withDefList) }
		return withWikilinks
	}

	/// Runs the seven per-line preprocessors in a single shared loop. Each
	/// processor's `applyLine` bakes in its own per-line fast-fail and any
	/// special skip conditions (e.g. SmartQuotes skipping link reference
	/// definitions), so we don't need to know per-processor specifics here.
	private static func mergedLinePass(_ text: String, options: MarkdownOptions) -> String {
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
			processed = EmoticonShortcodes.applyLine(processed)
			processed = SmartQuotes.applyLine(processed)
			processed = SmartTypography.applyLine(processed)
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
