//
//  MarkdownPreprocessor.swift
//  FeltTip
//

import Foundation

/// Centralizes the order in which markdown text passes through our pre-parse
/// processors. Used by `MarkdownBlockParser` for its non-preprocessed path and
/// kept in step with the manual preprocessing in `FormattedMarkdownScreen`,
/// which has to invoke the processors directly so it can keep references to
/// the parsed citations and footnotes for side panels.
public enum MarkdownPreprocessor {
	public static func process(_ body: String, options: MarkdownOptions = .default, preservingSourceText: Bool = false) -> String {
		processCancellable(
			body, options: options,
			preservingSourceText: preservingSourceText) ?? body
	}

	/// Rendering runs preprocessing inside cancellable tasks. Return nil once
	/// that task is obsolete so a superseded large-document render does not
	/// continue through the remaining document-wide passes. The public
	/// synchronous API above falls back to its unchanged input if its caller is
	/// already cancelled; parser callers discard the result at their next
	/// cancellation guard.
	private static func processCancellable(
		_ body: String,
		options: MarkdownOptions,
		preservingSourceText: Bool
	) -> String? {
		guard !Task.isCancelled else { return nil }
		let citations = Citation.parse(from: body)
		guard !Task.isCancelled else { return nil }
		let withCitations = Citation.renderableContent(from: body, citations: citations)
		guard !Task.isCancelled else { return nil }
		let footnotes = MarkdownFootnote.parse(from: withCitations)
		guard !Task.isCancelled else { return nil }
		let withFootnotes = MarkdownFootnote.renderableContent(from: withCitations, footnotes: footnotes)
		guard !Task.isCancelled else { return nil }
		let withAppendedNotes = appendFootnoteSection(to: withFootnotes, footnotes: footnotes)
		return commonCancellable(
			after: withAppendedNotes, options: options,
			preservingSourceText: preservingSourceText)
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
		let tracked = processTrackingOptionalOffsets(body, options: options)
		return (
			tracked.processed,
			tracked.map ?? Array(0..<tracked.processed.utf16.count)
		)
	}

	/// Parser-facing form of `processTrackingOffsets`. A nil map means the
	/// processed source is byte-for-byte identical, which is by far the common
	/// editable-document case. Keeping identity implicit avoids two full UTF-16
	/// copies plus a document-sized `[Int]` allocation on every render.
	static func processTrackingOptionalOffsets(
		_ body: String,
		options: MarkdownOptions = .default
	) -> (processed: String, map: [Int]?) {
		guard let processed = processCancellable(
			body, options: options, preservingSourceText: true
		) else {
			return (body, nil)
		}
		return (
			processed,
			processed == body ? nil : offsetMap(from: body, to: processed)
		)
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
		// Build the transformed offset array in one pass. Replaying the diff
		// with Array.remove/insert made documents with a rewrite on every line
		// quadratic: each mutation shifted the rest of a document-sized array.
		// Surviving source positions stream into non-inserted destination slots;
		// synthesized slots inherit the same nearest-neighbour offset as before.
		let removed = Set(diff.removals.compactMap { change -> Int? in
			if case let .remove(offset, _, _) = change { return offset }
			return nil
		})
		let inserted = Set(diff.insertions.compactMap { change -> Int? in
			if case let .insert(offset, _, _) = change { return offset }
			return nil
		})
		var survivors: [Int] = []
		survivors.reserveCapacity(srcMiddle.count - removed.count)
		for offset in srcMiddle.indices where !removed.contains(offset) {
			survivors.append(prefix + offset)
		}
		var offsets: [Int] = []
		offsets.reserveCapacity(dstMiddle.count)
		var survivorIndex = 0
		for offset in dstMiddle.indices {
			if inserted.contains(offset) {
				let neighbor = offsets.last
					?? (survivorIndex < survivors.count
						? survivors[survivorIndex]
						: (prefix > 0 ? prefix - 1 : 0))
				offsets.append(neighbor)
			} else {
				offsets.append(survivors[survivorIndex])
				survivorIndex += 1
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
		commonCancellable(
			after: withFootnotes, options: options,
			preservingSourceText: preservingSourceText) ?? withFootnotes
	}

	private static func commonCancellable(
		after withFootnotes: String,
		options: MarkdownOptions,
		preservingSourceText: Bool
	) -> String? {
		guard !Task.isCancelled else { return nil }
		let collectTimings = recordsPerformanceMetrics
		func timed<T>(_ label: String, _ work: () -> T) -> T {
			guard collectTimings else { return work() }
			let t = CFAbsoluteTimeGetCurrent()
			let result = work()
			Self.recordTiming(label, ms: (CFAbsoluteTimeGetCurrent() - t) * 1000)
			return result
		}
		let withAbbreviations = timed("Abbreviation") { AbbreviationProcessor.process(withFootnotes) }
		guard !Task.isCancelled else { return nil }
		let withContainers = timed("CustomContainer") { CustomContainerProcessor.process(withAbbreviations) }
		guard !Task.isCancelled else { return nil }
		// All seven of the per-line processors run inside a single split-
		// iterate-join pass — we used to do ten separate ones, which cost
		// ~80 ms of pure split/join on a 200-section document. Order is
		// preserved against the previous chain (Heading → SuperSub → Inserted
		// → Emoticon → SmartQuotes → SmartTypography → Highlight). HeadingSpace
		// used to run before Abbreviation/CustomContainer; neither of those
		// inspects heading syntax so the move is behaviour-preserving.
		guard let withLinePass = timed("LinePass", {
			mergedLinePass(
				withContainers, options: options,
				preservingSourceText: preservingSourceText)
		}) else {
			return nil
		}
		guard !Task.isCancelled else { return nil }
		let withEmoji = preservingSourceText ? withLinePass : timed("Emoji") { EmojiShortcodes.process(withLinePass) }
		guard !Task.isCancelled else { return nil }
		let withDefList = timed("DefinitionList") { DefinitionListProcessor.process(withEmoji) }
		guard !Task.isCancelled else { return nil }
		let withWikilinks = timed("Wikilink") { WikilinkProcessor.process(withDefList) }
		guard !Task.isCancelled else { return nil }
		return withWikilinks
	}

	/// Runs the seven per-line preprocessors in a single shared loop. Each
	/// processor's `applyLine` bakes in its own per-line fast-fail and any
	/// special skip conditions (e.g. SmartQuotes skipping link reference
	/// definitions), so we don't need to know per-processor specifics here.
	private static func mergedLinePass(
		_ text: String,
		options: MarkdownOptions,
		preservingSourceText: Bool
	) -> String? {
		let features = LinePassFeatures(
			text: text,
			options: options,
			preservingSourceText: preservingSourceText)
		guard features.requiresPass else { return text }
		var output: [String] = []
		var inFence = false
		var referenceContinuationLines = 0
		let lines = text.components(separatedBy: "\n")
		output.reserveCapacity(lines.count)
		for (index, line) in lines.enumerated() {
			if index & 63 == 0, Task.isCancelled { return nil }
			if features.fences {
				let trimmed = line.trimmingCharacters(in: .whitespaces)
				if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
					inFence.toggle()
					referenceContinuationLines = 0
					output.append(line); continue
				}
				if inFence { output.append(line); continue }
			}
			if features.blockAttributes,
			   KramdownAttributeListProcessor.isStandaloneAttributeList(line) {
				output.append("")
				continue
			}
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			var preservesReferenceSyntax = false
			if referenceContinuationLines > 0,
			   !trimmed.isEmpty,
			   (line.first == " " || line.first == "\t") {
				preservesReferenceSyntax = true
				referenceContinuationLines -= 1
			} else if !trimmed.isEmpty {
				referenceContinuationLines = 0
			}
			if let continuationLimit = SmartQuotes.referenceDefinitionContinuationLimit(trimmed) {
				preservesReferenceSyntax = true
				referenceContinuationLines = continuationLimit
			}
			var processed = line
			if features.headings { processed = HeadingSpaceInjector.applyLine(processed) }
			if features.superSub { processed = SuperSubProcessor.applyLine(processed) }
			if features.inserted { processed = InsertedTextProcessor.applyLine(processed) }
			if features.emoticons {
				processed = EmoticonShortcodes.applyLine(processed)
			}
			if features.quotes && !preservesReferenceSyntax {
				processed = SmartQuotes.applyLine(processed)
			}
			if features.typography {
				processed = SmartTypography.applyLine(processed)
			}
			if features.highlight { processed = HighlightSyntax.applyLine(processed) }
			output.append(processed)
		}
		guard !Task.isCancelled else { return nil }
		return output.joined(separator: "\n")
	}

	private struct LinePassFeatures {
		let fences: Bool
		let blockAttributes: Bool
		let headings: Bool
		let superSub: Bool
		let inserted: Bool
		let emoticons: Bool
		let quotes: Bool
		let typography: Bool
		let highlight: Bool

		var requiresPass: Bool {
			fences || blockAttributes || headings || superSub || inserted
				|| emoticons || quotes || typography || highlight
		}

		init(
			text: String,
			options: MarkdownOptions,
			preservingSourceText: Bool
		) {
			let wholeRange = NSRange(text.startIndex..., in: text)
			let hasStructuralCandidate = Self.structuralPattern.firstMatch(
				in: text, range: wholeRange) != nil
			let hasEmoticon = !preservingSourceText
				&& EmoticonShortcodes.containsToken(in: text)
			let hasCosmeticCandidate = !preservingSourceText
				&& Self.cosmeticPattern.firstMatch(in: text, range: wholeRange) != nil
			guard hasStructuralCandidate || hasEmoticon || hasCosmeticCandidate else {
				fences = false
				blockAttributes = false
				headings = false
				superSub = false
				inserted = false
				emoticons = false
				quotes = false
				typography = false
				highlight = false
				return
			}

			let source = text as NSString
			func contains(_ marker: String) -> Bool {
				source.range(of: marker).location != NSNotFound
			}

			fences = contains("```") || contains("~~~")
			blockAttributes = contains("{:")
			headings = !options.headingsRequireSpaceAfterHash && contains("#")
			superSub = contains("^") || contains("~")
			inserted = contains("++")
			highlight = contains("==")
			if preservingSourceText {
				emoticons = false
				quotes = false
				typography = false
			} else {
				emoticons = hasEmoticon
				quotes = contains("\"") || contains("'")
				typography = contains("(") || contains("+-") || contains("...") || contains("--")
			}
		}

		private static let structuralPattern = try! NSRegularExpression(
			pattern: #"```|~~~|\{\:|#|\^|~|\+\+|=="#
		)
		private static let cosmeticPattern = try! NSRegularExpression(
			pattern: #"["']|\(|\+-|\.\.\.|--"#
		)
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
	/// Opt-in switch for the ad-hoc render benchmark instrumentation. Keeping
	/// this off in normal app and test runs avoids clocks and shared-state
	/// locking in every preprocessing pass.
	public static var recordsPerformanceMetrics: Bool {
		get {
			recordedLock.lock(); defer { recordedLock.unlock() }
			return _recordsPerformanceMetrics
		}
		set {
			recordedLock.lock(); defer { recordedLock.unlock() }
			_recordsPerformanceMetrics = newValue
		}
	}
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
	nonisolated(unsafe) private static var _recordsPerformanceMetrics = false
	nonisolated(unsafe) private static var _recordedTimings: [String: Double] = [:]

	fileprivate static func recordTiming(_ label: String, ms: Double) {
		recordedLock.lock(); defer { recordedLock.unlock() }
		_recordedTimings[label, default: 0] += ms
	}
}
