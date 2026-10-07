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
		// Earlier passes hand back NSString-bridged strings, whose UTF-8 view is
		// transcoded on every access. One contiguous copy up front makes every
		// byte scan below a plain memory read; lines are then substrings of it
		// and the output is built in place rather than split, mapped, and joined.
		var text = text
		text.makeContiguousUTF8()
		let features = LinePassFeatures(
			scan: text.withUTF8 { ASCIILineScan(bytes: $0) },
			options: options,
			preservingSourceText: preservingSourceText)
		guard features.requiresPass else { return text }
		var result = ""
		result.reserveCapacity(text.utf8.count + 64)
		var inFence = false
		var referenceContinuationLines = 0
		let utf8 = text.utf8
		var lineStart = utf8.startIndex
		var lineIndex = 0
		while true {
			let lineEnd = utf8[lineStart...].firstIndex(of: 0x0A) ?? utf8.endIndex
			if lineIndex & 63 == 0, Task.isCancelled { return nil }
			lineIndex += 1
			if lineIndex > 1 { result.append("\n") }
			let line = text[lineStart..<lineEnd]
			result.append(contentsOf: processLine(
				line, features: features, inFence: &inFence,
				referenceContinuationLines: &referenceContinuationLines))
			if lineEnd == utf8.endIndex { break }
			lineStart = utf8.index(after: lineEnd)
		}
		guard !Task.isCancelled else { return nil }
		return result
	}

	/// One line of the merged pass. One byte pass decides everything about
	/// the line: which processors can possibly apply (a processor never
	/// introduces a marker it did not have, so the original line's markers are
	/// a safe superset for every later stage), whether the byte-level fast
	/// paths may run, and where the whitespace trim falls.
	private static func processLine(
		_ line: Substring,
		features: LinePassFeatures,
		inFence: inout Bool,
		referenceContinuationLines: inout Int
	) -> Substring {
		let scan = ASCIILineScan(line)
		let trimmed: Substring
		if scan.isASCII {
			let utf8 = line.utf8
			let start = utf8.index(utf8.startIndex, offsetBy: scan.leadingWhitespace)
			let end = utf8.index(utf8.endIndex, offsetBy: -min(scan.trailingWhitespace, scan.byteCount - scan.leadingWhitespace))
			trimmed = line[start..<end]
		} else {
			trimmed = Substring(line.trimmingCharacters(in: .whitespaces))
		}
		if features.fences {
			// Grapheme-aware `hasPrefix` is slow enough to show up per line;
			// three ASCII bytes answer the same question on ASCII lines.
			let opensFence: Bool
			if scan.isASCII {
				let u = trimmed.utf8
				if u.count >= 3 {
					let i0 = u.startIndex, i1 = u.index(after: i0), i2 = u.index(after: i1)
					opensFence = (u[i0] == 0x60 && u[i1] == 0x60 && u[i2] == 0x60)
						|| (u[i0] == 0x7E && u[i1] == 0x7E && u[i2] == 0x7E)
				} else {
					opensFence = false
				}
			} else {
				opensFence = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
			}
			if opensFence {
				inFence.toggle()
				referenceContinuationLines = 0
				return line
			}
			if inFence { return line }
		}
		if features.blockAttributes, scan.hasOpenBrace,
		   KramdownAttributeListProcessor.isStandaloneAttributeList(trimmed: trimmed) {
			return ""
		}
		var preservesReferenceSyntax = false
		if referenceContinuationLines > 0,
		   !trimmed.isEmpty,
		   scan.isASCII ? (line.utf8.first == 0x20 || line.utf8.first == 0x09)
		                : (line.first == " " || line.first == "\t") {
			preservesReferenceSyntax = true
			referenceContinuationLines -= 1
		} else if !trimmed.isEmpty {
			referenceContinuationLines = 0
		}
		// A reference definition starts its trimmed line with `[`; most lines
		// with a bracket are links, so check that byte before the full test.
		if scan.hasOpenBracket, trimmed.utf8.first == 0x5B,
		   let continuationLimit = SmartQuotes.referenceDefinitionContinuationLimit(trimmed) {
			preservesReferenceSyntax = true
			referenceContinuationLines = continuationLimit
		}
		var processed = line
		if features.headings, scan.hasHash { processed = Substring(HeadingSpaceInjector.applyLine(String(processed))) }
		if features.superSub, scan.hasCaret || scan.hasTilde { processed = Substring(SuperSubProcessor.applyLine(String(processed))) }
		if features.inserted, scan.hasPlusPlus { processed = Substring(InsertedTextProcessor.applyLine(String(processed))) }
		if features.emoticons, scan.hasEmoticonSeed {
			switch EmoticonShortcodes.applyASCIILine(processed) {
			case .unchanged: break
			case .changed(let result): processed = Substring(result)
			case .notASCII: processed = Substring(EmoticonShortcodes.applyLine(String(processed)))
			}
		}
		if features.quotes, !preservesReferenceSyntax, scan.hasDoubleQuote || scan.hasSingleQuote {
			switch SmartQuotes.applyASCIILine(processed) {
			case .unchanged: break
			case .changed(let result): processed = Substring(result)
			case .notASCII: processed = Substring(SmartQuotes.applyLine(String(processed)))
			}
		}
		if features.typography, scan.hasParen || scan.hasPlusMinus || scan.hasEllipsis || scan.hasDoubleDash {
			switch SmartTypography.applyASCIILine(processed) {
			case .unchanged: break
			case .changed(let result): processed = Substring(result)
			case .notASCII: processed = Substring(SmartTypography.applyLine(String(processed)))
			}
		}
		if features.highlight, scan.hasEqualsEquals { processed = Substring(HighlightSyntax.applyLine(String(processed))) }
		return processed
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

		/// One byte pass over the document decides which processors can
		/// matter. The previous implementation ran two regexes and a dozen
		/// `NSString.range(of:)` searches, each transcoding the native string to
		/// UTF-16, which cost more than the whole per-line pass they gated.
		init(
			scan: ASCIILineScan,
			options: MarkdownOptions,
			preservingSourceText: Bool
		) {
			fences = scan.hasTripleBacktick || scan.hasTripleTilde
			blockAttributes = scan.hasBraceColon
			headings = !options.headingsRequireSpaceAfterHash && scan.hasHash
			superSub = scan.hasCaret || scan.hasTilde
			inserted = scan.hasPlusPlus
			highlight = scan.hasEqualsEquals
			if preservingSourceText {
				emoticons = false
				quotes = false
				typography = false
			} else {
				emoticons = scan.hasEmoticonSeed
				quotes = scan.hasDoubleQuote || scan.hasSingleQuote
				typography = scan.hasParen || scan.hasPlusMinus || scan.hasEllipsis || scan.hasDoubleDash
			}
		}
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
