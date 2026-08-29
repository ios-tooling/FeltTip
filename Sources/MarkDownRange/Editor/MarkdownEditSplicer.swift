//
//  MarkdownEditSplicer.swift
//  MarkDownRange
//
//  Pure verify-and-splice logic behind the editable web view's edit bridge.
//  An edit arrives as source offsets plus the text the DOM shows inside and
//  around the range; the splice only applies when the source agrees. The
//  replaced text alone can't protect insertions — a collapsed range has
//  nothing to verify — so the surrounding context is what stops a stale or
//  drifted offset from splicing into the wrong place. Any rejection means the
//  DOM and source may disagree, and the caller re-renders to resync.
//

import Foundation

enum MarkdownEditSplicer {
	struct Edit {
		var start: Int
		var end: Int
		/// Replacement for the range; nil for a wrap edit.
		var replacement: String?
		/// Marker to wrap the range in (bold/italic); nil for a splice.
		var wrapMarker: String?
		/// Toggle the range as inline code, choosing a safe backtick delimiter.
		var inlineCode = false
		/// Shared source-level formatting command used by menu actions.
		var formatCommand: MarkdownFormattingCommand?
		/// The text the DOM shows inside the range. Not checked for cross-run
		/// edits: there the DOM omits the markdown syntax between runs.
		var expected: String
		var crossRun: Bool
		/// True when the user had a real selection. A cross-run delete with a
		/// selection may remove the syntax hidden inside it; a collapsed-caret
		/// delete (a block merge) may only remove whitespace — silently eating
		/// a `**` or list marker would corrupt the structure around the caret.
		var selected = false
		/// DOM text immediately before/after the range, within its runs.
		var before: String
		var after: String
		/// Inline DOM elements whose complete visible start/end boundary was
		/// selected by a deletion. Their Markdown syntax is hidden from the range and
		/// must be consumed with the visible text to avoid orphan delimiters.
		var syntaxStart: [String] = []
		var syntaxEnd: [String] = []
		/// Inline syntax immediately after a collapsed caret at the visible end
		/// of a formatted run. Structural insertion commands such as Return must
		/// land after those verified hidden delimiters, not inside them.
		var collapsedSyntaxEnd: [String] = []
		/// Block markers whose complete visible block was selected for deletion.
		var blockPrefixes: [String] = []
		/// Source offset to restore the caret to after a structural re-render;
		/// nil for in-place edits, which keep the browser's own caret.
		var caret: Int?
		/// The replacement is a list-item continuation ("\n- " / "\n1. ") the
		/// page composed from DOM structure. Only the source shows how deeply
		/// the item is indented and whether it is a task, so the splice matches
		/// both properties. A continued task is always created unchecked.
		var listBreak = false
		/// Enter was pressed at the first visible character of a block. The
		/// splice verifies any source prefix hidden by rendering (`# `, `> `,
		/// `**`, etc.) and inserts before it so the whole block moves.
		var blockStartBreak = false
		/// A DOM range ended at the first visible character of the following block
		/// (a paragraph-selection boundary or collapsed block merge). Its stamped
		/// offset sits after any hidden opening Markdown, so source operations must
		/// use the verified source line start instead.
		var endAtBlockStart = false
		/// The replacement ends a line with a hard break ("\\\n"). Whitespace
		/// left at the start of the following line is stripped when rendered,
		/// which would stamp that run at the whitespace instead of its first
		/// character, so the splice swallows it.
		var hardBreak = false
	}

	enum Outcome {
		/// The new source, plus the selection to restore after a structural
		/// re-render: style toggles keep the (shifted) selection selected;
		/// other edits collapse to their caret target.
		case applied(String, selection: NSRange?, replaced: String)
		case rejected(String)
	}

	static func apply(_ edit: Edit, to source: String) -> Outcome {
		let text = source as NSString
		guard edit.start >= 0, edit.end >= edit.start, edit.end <= text.length else {
			return .rejected("out-of-bounds start=\(edit.start) end=\(edit.end) len=\(text.length)")
		}
		// A boundary inside a surrogate pair would split it: the source would
		// hold a lone surrogate that mangles to U+FFFD crossing the JSON
		// bridge, desyncing every later verification. The page snaps carets
		// to pair boundaries; this is the safety net for offsets that arrive
		// by other routes.
		if splitsSurrogatePair(text, at: edit.start) || splitsSurrogatePair(text, at: edit.end) {
			return .rejected("range splits a surrogate pair start=\(edit.start) end=\(edit.end)")
		}
		let reportedRange = NSRange(location: edit.start, length: edit.end - edit.start)
		let actual = text.substring(with: reportedRange)
		if !edit.crossRun, plain(actual) != plain(edit.expected) {
			return .rejected("expected mismatch range=\(reportedRange) expected=\(quoted(edit.expected)) actual=\(quoted(actual))")
		}
		if let reason = contextMismatch(edit, in: text) {
			return .rejected(reason)
		}
		var range = reportedRange
		if edit.endAtBlockStart {
			guard edit.end > edit.start,
				  let blockStart = verifiedBlockStart(in: text, visibleStart: edit.end),
				  blockStart >= edit.start else {
				return .rejected("invalid range end at visual block start \(edit.end)")
			}
			range = NSRange(location: edit.start, length: blockStart - edit.start)
		}
		if edit.crossRun, edit.wrapMarker == nil, edit.replacement?.isEmpty == true, !edit.selected {
			let deleted = text.substring(with: range)
			if deleted.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted) != nil {
				return .rejected("collapsed cross-run delete would remove syntax \(quoted(deleted))")
			}
		}
		if let command = edit.formatCommand {
			guard !edit.crossRun || command.supportsCrossRunSelection else {
				return .rejected("format command \(command.rawValue) crosses rendered runs")
			}
			guard let change = MarkdownSourceFormatter.change(
				in: source,
				selection: range,
				command: command) else {
				return .rejected("format command \(command.rawValue) made no change")
			}
			return .applied(
				text.replacingCharacters(in: change.range, with: change.replacement),
				selection: change.selection,
				replaced: text.substring(with: change.range))
		}
		if edit.inlineCode {
			guard !edit.crossRun else {
				return .rejected("inline-code toggle crosses rendered runs")
			}
			guard let change = MarkdownInlineCodeToggle.change(
				in: source,
				selection: NSRange(location: edit.start, length: edit.end - edit.start)) else {
				return .rejected("invalid inline-code selection")
			}
			return .applied(
				text.replacingCharacters(in: change.range, with: change.replacement),
				selection: change.selection,
				replaced: text.substring(with: change.range))
		}
		if let marker = edit.wrapMarker {
			// A cross-run DOM selection can stop immediately before hidden
			// Markdown delimiters. Blindly inserting a new pair there creates
			// overlapping source such as `~~Alpha **Beta~~**`. Until the bridge
			// can expand selections using parser source spans, veto any wrap
			// whose selected source crosses inline syntax rather than damaging
			// the document.
			if edit.crossRun, actual.rangeOfCharacter(
				from: CharacterSet(charactersIn: "*_~`[]()")) != nil {
				return .rejected("cross-run wrap intersects hidden inline syntax")
			}
			// Toggle, not just wrap: a selection whose source is already
			// wrapped in the marker (or its underscore twin) un-styles.
			// Stacking markers instead produced `****text****`. Either way
			// the restored selection covers the same content, shifted by the
			// markers added or removed.
			let alternates = marker == "**" ? ["**", "__"] : marker == "*" ? ["*", "_"] : [marker]
			for alternate in alternates {
				let length = (alternate as NSString).length
				if edit.start >= length, edit.end + length <= text.length,
				   text.substring(with: NSRange(location: edit.start - length, length: length)) == alternate,
				   text.substring(with: NSRange(location: edit.end, length: length)) == alternate {
					let unwrapped = text.substring(to: edit.start - length) + actual + text.substring(from: edit.end + length)
					let replacedRange = NSRange(
						location: edit.start - length,
						length: edit.end - edit.start + 2 * length)
					return .applied(
						unwrapped,
						selection: NSRange(location: edit.start - length, length: edit.end - edit.start),
						replaced: text.substring(with: replacedRange))
				}
			}
			let markerLength = (marker as NSString).length
			let wrapped = text.substring(to: edit.start) + marker + actual + marker + text.substring(from: edit.end)
			return .applied(
				wrapped,
				selection: NSRange(location: edit.start + markerLength, length: edit.end - edit.start),
				replaced: actual)
		}
		guard var replacement = edit.replacement else {
			return .rejected("no replacement or marker")
		}
		var caret = edit.caret
		// Re-indent a list continuation to the item it continues; without this a
		// nested item's Enter produced a top-level item and reflowed the list.
		if edit.listBreak, replacement.hasPrefix("\n") {
			let indent = lineIndent(in: text, at: edit.start)
			if isTaskListItem(in: text, at: edit.start) {
				replacement += "[ ] "
				caret = caret.map { $0 + 4 }
			}
			if !indent.isEmpty {
				replacement = "\n" + indent + replacement.dropFirst()
				caret = caret.map { $0 + (indent as NSString).length }
			}
		}
		// A hard break takes the following line's leading whitespace with it: the
		// renderer strips that whitespace, and a stamped run whose text has lost
		// characters the source still has no longer addresses its own offset.
		var spliceRange = range
		if range.length == 0, !edit.collapsedSyntaxEnd.isEmpty {
			guard let expanded = syntaxExpandedRange(
				range,
				syntaxStart: [],
				syntaxEnd: edit.collapsedSyntaxEnd,
				in: text
			) else {
				return .rejected("collapsed-caret syntax boundary does not match source")
			}
			let shift = expanded.upperBound - range.location
			spliceRange = NSRange(location: expanded.upperBound, length: 0)
			caret = caret.map { $0 + shift }
		}
		if edit.crossRun, replacement.isEmpty, !edit.selected,
		   range.length > 0 {
			let deleted = text.substring(with: range) as NSString
			let containsLineBreak = (0..<deleted.length).contains {
				let unit = deleted.character(at: $0)
				return unit == 0x0A || unit == 0x0D
			}
			if containsLineBreak {
				var preservedPrefix = 0
				while preservedPrefix < deleted.length {
					let unit = deleted.character(at: preservedPrefix)
					guard unit == 0x20 || unit == 0x09 else { break }
					preservedPrefix += 1
				}
				if preservedPrefix > 0 {
					// A trailing space before a soft wrap is not represented by a
					// stamped DOM run. Backspace at the following visual line start
					// therefore reports it together with the paragraph separator.
					// Keep that pre-existing whitespace and remove only the break.
					spliceRange = NSRange(
						location: range.location + preservedPrefix,
						length: range.length - preservedPrefix)
					caret = spliceRange.location
				}
			}
		}
		if edit.blockStartBreak {
			guard range.length == 0, replacement == "\n\n",
				  let lineStart = verifiedBlockStart(
					in: text, visibleStart: edit.start)
			else {
				return .rejected("invalid visual block-start break at \(edit.start)")
			}
			spliceRange = NSRange(location: lineStart, length: 0)
			// Return at a block's visual start moves the whole prefixed block
			// down and keeps the insertion point with its first visible character.
			caret = lineStart + (replacement as NSString).length
		}
		let replacementOwnsInlineSyntax = edit.selected && (replacement.isEmpty || edit.crossRun)
		let replacementOwnsBlockPrefix = edit.selected && replacement.isEmpty
		let replacementSyntaxStart = replacementOwnsInlineSyntax ? edit.syntaxStart : []
		let replacementSyntaxEnd = replacementOwnsInlineSyntax ? edit.syntaxEnd : []
		let replacementBlockPrefixes = replacementOwnsBlockPrefix ? edit.blockPrefixes : []
		if !replacementSyntaxStart.isEmpty || !replacementSyntaxEnd.isEmpty ||
		   !replacementBlockPrefixes.isEmpty {
			guard let expanded = syntaxExpandedReplacementRange(
				range,
				syntaxStart: replacementSyntaxStart,
				syntaxEnd: replacementSyntaxEnd,
				blockPrefixes: replacementBlockPrefixes,
				in: text
			) else {
				return .rejected("replacement syntax boundaries do not match source")
			}
			spliceRange = expanded
			caret = expanded.location + (replacement as NSString).length
		}
		if edit.hardBreak, replacement.hasSuffix("\n") {
			var cursor = edit.end
			while cursor < text.length, text.character(at: cursor) == 0x20 || text.character(at: cursor) == 0x09 {
				cursor += 1
			}
			spliceRange = NSRange(location: edit.start, length: cursor - edit.start)
		}
		return .applied(
			text.replacingCharacters(in: spliceRange, with: replacement),
			selection: caret.map { NSRange(location: $0, length: 0) },
			replaced: text.substring(with: spliceRange))
	}

	private static let taskListPrefix = try! NSRegularExpression(
		pattern: #"^[ \t]*(?:[-+*]|[0-9]+[.)])[ \t]+\[[ xX]\][ \t]+"#)

	/// Whether the source line containing the edit is a task-list item. The DOM
	/// exposes the surrounding `<li>` but intentionally hides `[ ]` / `[x]`,
	/// so this distinction must be recovered from the verified source.
	private static func isTaskListItem(
		in text: NSString,
		at offset: Int
	) -> Bool {
		var lineStart = min(max(0, offset), text.length)
		while lineStart > 0 {
			let previous = text.character(at: lineStart - 1)
			if previous == 0x0A || previous == 0x0D { break }
			lineStart -= 1
		}
		let prefix = text.substring(with: NSRange(
			location: lineStart,
			length: min(max(0, offset - lineStart), text.length - lineStart)))
		let range = NSRange(location: 0, length: (prefix as NSString).length)
		return taskListPrefix.firstMatch(in: prefix, range: range) != nil
	}

	/// Verifies that the hidden portion before a block's first visible run
	/// actually begins with the declared Markdown structure. Content after the
	/// structural marker may itself begin with hidden inline syntax (`**`), so
	/// the visible stamp is allowed to sit later than the marker.
	static func verifiedBlockStart(in text: NSString, visibleStart: Int) -> Int? {
		guard visibleStart >= 0, visibleStart <= text.length else { return nil }
		var lineStart = visibleStart
		while lineStart > 0 {
			let previous = text.character(at: lineStart - 1)
			if previous == 0x0A || previous == 0x0D { break }
			lineStart -= 1
		}
		let hidden = text.substring(with: NSRange(
			location: lineStart, length: visibleStart - lineStart))
		// A stale or forged flag must not pull visible prose into the moved
		// block. Legitimately hidden Markdown prefixes contain only whitespace
		// and punctuation; letters/numbers mean this was not the visual start.
		guard hidden.rangeOfCharacter(from: .alphanumerics) == nil,
			  hidden.rangeOfCharacter(from: .newlines) == nil else {
			return nil
		}
		return lineStart
	}

	/// Leading whitespace of the line containing `offset`.
	private static func lineIndent(in text: NSString, at offset: Int) -> String {
		var lineStart = min(max(0, offset), text.length)
		while lineStart > 0, text.character(at: lineStart - 1) != 0x0A { lineStart -= 1 }
		var end = lineStart
		while end < text.length, text.character(at: end) == 0x20 || text.character(at: end) == 0x09 { end += 1 }
		return text.substring(with: NSRange(location: lineStart, length: end - lineStart))
	}

	private static func syntaxExpandedReplacementRange(
		_ range: NSRange,
		syntaxStart: [String],
		syntaxEnd: [String],
		blockPrefixes: [String],
		in text: NSString
	) -> NSRange? {
		guard var expanded = syntaxExpandedRange(
			range, syntaxStart: syntaxStart,
			syntaxEnd: syntaxEnd, in: text) else { return nil }
		var start = expanded.location
		let end = expanded.upperBound
		for prefix in blockPrefixes {
			switch prefix {
			case "heading":
				guard consumeHeadingPrefixBefore(cursor: &start, in: text) else { return nil }
			case "list":
				guard consumeListPrefixBefore(cursor: &start, in: text) else { return nil }
			case "blockquote":
				guard consumeBefore(["> ", ">"], cursor: &start, in: text) else { return nil }
			default:
				return nil
			}
		}
		expanded = NSRange(location: start, length: end - start)
		return expanded
	}

	/// Expands a visible selection over inline Markdown delimiters that its DOM
	/// boundaries own. Used both by destructive edits and source-selection
	/// mirroring so double/triple-click selections include attached formatting.
	static func syntaxExpandedRange(
		_ range: NSRange,
		syntaxStart: [String],
		syntaxEnd: [String],
		in text: NSString
	) -> NSRange? {
		guard range.location >= 0, range.length >= 0,
		      range.location <= text.length,
		      range.length <= text.length - range.location else { return nil }
		var start = range.location
		var end = range.upperBound
		// Attribute rendering may normalize nested DOM tags into an order that
		// differs from the authored Markdown delimiters (for example
		// `~~**text**~~` can render with <del>/<strong> ancestry reversed).
		// Consume the exact declared set in whichever order the verified source
		// boundary actually contains instead of trusting DOM ancestry order.
		guard consumeSyntaxStart(syntaxStart, cursor: &start, in: text) else { return nil }
		guard consumeSyntaxEnd(syntaxEnd, cursor: &end, in: text) else { return nil }
		return NSRange(location: start, length: end - start)
	}

	private static func consumeSyntaxStart(
		_ tags: [String],
		cursor: inout Int,
		in text: NSString
	) -> Bool {
		var failedStates: Set<String> = []
		return consumeSyntaxStart(
			tags, cursor: &cursor, in: text, failedStates: &failedStates)
	}

	private static func consumeSyntaxStart(
		_ tags: [String],
		cursor: inout Int,
		in text: NSString,
		failedStates: inout Set<String>
	) -> Bool {
		guard !tags.isEmpty else { return true }
		let state = syntaxConsumptionState(cursor: cursor, tags: tags)
		guard !failedStates.contains(state) else { return false }
		var attemptedTags: Set<String> = []
		for index in tags.indices {
			guard attemptedTags.insert(tags[index]).inserted else { continue }
			var candidateCursor = cursor
			guard consumeSyntaxStartTag(tags[index], cursor: &candidateCursor, in: text) else { continue }
			var remaining = tags
			remaining.remove(at: index)
			if consumeSyntaxStart(
				remaining, cursor: &candidateCursor, in: text,
				failedStates: &failedStates
			) {
				cursor = candidateCursor
				return true
			}
		}
		failedStates.insert(state)
		return false
	}

	private static func consumeSyntaxEnd(
		_ tags: [String],
		cursor: inout Int,
		in text: NSString
	) -> Bool {
		var failedStates: Set<String> = []
		return consumeSyntaxEnd(
			tags, cursor: &cursor, in: text, failedStates: &failedStates)
	}

	private static func consumeSyntaxEnd(
		_ tags: [String],
		cursor: inout Int,
		in text: NSString,
		failedStates: inout Set<String>
	) -> Bool {
		guard !tags.isEmpty else { return true }
		let state = syntaxConsumptionState(cursor: cursor, tags: tags)
		guard !failedStates.contains(state) else { return false }
		var attemptedTags: Set<String> = []
		for index in tags.indices {
			guard attemptedTags.insert(tags[index]).inserted else { continue }
			var candidateCursor = cursor
			guard consumeSyntaxEndTag(tags[index], cursor: &candidateCursor, in: text) else { continue }
			var remaining = tags
			remaining.remove(at: index)
			if consumeSyntaxEnd(
				remaining, cursor: &candidateCursor, in: text,
				failedStates: &failedStates
			) {
				cursor = candidateCursor
				return true
			}
		}
		failedStates.insert(state)
		return false
	}

	private static func syntaxConsumptionState(cursor: Int, tags: [String]) -> String {
		"\(cursor)|\(tags.sorted().joined(separator: ","))"
	}

	private static func consumeSyntaxStartTag(
		_ tag: String,
		cursor: inout Int,
		in text: NSString
	) -> Bool {
		switch tag {
		case "strong": consumeBefore(["**", "__"], cursor: &cursor, in: text)
		case "em": consumeBefore(["*", "_"], cursor: &cursor, in: text)
		case "u": consumeBefore(["<u>"], cursor: &cursor, in: text)
		case "del": consumeBefore(["~~"], cursor: &cursor, in: text)
		case "mark": consumeBefore(["=="], cursor: &cursor, in: text)
		case "sup": consumeBefore(["^"], cursor: &cursor, in: text)
		case "sub": consumeBefore(["~"], cursor: &cursor, in: text)
		case "code": consumeCodeDelimiterBefore(cursor: &cursor, in: text)
		case "a": consumeBefore(["["], cursor: &cursor, in: text)
		default: false
		}
	}

	private static func consumeSyntaxEndTag(
		_ tag: String,
		cursor: inout Int,
		in text: NSString
	) -> Bool {
		switch tag {
		case "strong": consumeAfter(["**", "__"], cursor: &cursor, in: text)
		case "em": consumeAfter(["*", "_"], cursor: &cursor, in: text)
		case "u": consumeAfter(["</u>"], cursor: &cursor, in: text)
		case "del": consumeAfter(["~~"], cursor: &cursor, in: text)
		case "mark": consumeAfter(["=="], cursor: &cursor, in: text)
		case "sup": consumeAfter(["^"], cursor: &cursor, in: text)
		case "sub": consumeAfter(["~"], cursor: &cursor, in: text)
		case "code": consumeCodeDelimiterAfter(cursor: &cursor, in: text)
		case "a": consumeLinkSuffix(cursor: &cursor, in: text)
		default: false
		}
	}

	private static func consumeBefore(
		_ candidates: [String],
		cursor: inout Int,
		in text: NSString
	) -> Bool {
		guard cursor >= 0, cursor <= text.length else { return false }
		for candidate in candidates {
			let length = (candidate as NSString).length
			guard cursor >= length else { continue }
			if text.substring(with: NSRange(location: cursor - length, length: length)) == candidate {
				cursor -= length
				return true
			}
		}
		return false
	}

	private static func consumeAfter(
		_ candidates: [String],
		cursor: inout Int,
		in text: NSString
	) -> Bool {
		guard cursor >= 0, cursor <= text.length else { return false }
		for candidate in candidates {
			let length = (candidate as NSString).length
			guard length <= text.length - cursor else { continue }
			if text.substring(with: NSRange(location: cursor, length: length)) == candidate {
				cursor += length
				return true
			}
		}
		return false
	}

	private static func consumeCodeDelimiterBefore(cursor: inout Int, in text: NSString) -> Bool {
		guard cursor >= 0, cursor <= text.length else { return false }
		var scan = cursor
		if scan > 0, text.character(at: scan - 1) == 0x20 { scan -= 1 }
		let contentEnd = scan
		while scan > 0, text.character(at: scan - 1) == 0x60 { scan -= 1 }
		guard scan < contentEnd else { return false }
		cursor = scan
		return true
	}

	private static func consumeCodeDelimiterAfter(cursor: inout Int, in text: NSString) -> Bool {
		guard cursor >= 0, cursor <= text.length else { return false }
		var scan = cursor
		if scan < text.length, text.character(at: scan) == 0x20 { scan += 1 }
		let contentStart = scan
		while scan < text.length, text.character(at: scan) == 0x60 { scan += 1 }
		guard scan > contentStart else { return false }
		cursor = scan
		return true
	}

	private static func consumeHeadingPrefixBefore(cursor: inout Int, in text: NSString) -> Bool {
		guard cursor >= 0, cursor <= text.length else { return false }
		var scan = cursor
		guard scan > 0, isHorizontalSpace(text.character(at: scan - 1)) else { return false }
		while scan > 0, isHorizontalSpace(text.character(at: scan - 1)) { scan -= 1 }
		let hashesEnd = scan
		while scan > 0, text.character(at: scan - 1) == 0x23, hashesEnd - scan < 6 { scan -= 1 }
		guard scan < hashesEnd else { return false }
		cursor = scan
		return true
	}

	private static func consumeListPrefixBefore(cursor: inout Int, in text: NSString) -> Bool {
		guard cursor >= 0, cursor <= text.length else { return false }
		var lineStart = cursor
		while lineStart > 0 {
			let character = text.character(at: lineStart - 1)
			if character == 0x0A || character == 0x0D { break }
			lineStart -= 1
		}
		let prefix = text.substring(with: NSRange(location: lineStart, length: cursor - lineStart))
		let expression = try! NSRegularExpression(
			pattern: #"(?:[-+*][ \t]+(?:\[[ xX]\][ \t]+)?|[0-9]+[.)][ \t]+)$"#)
		let full = NSRange(location: 0, length: (prefix as NSString).length)
		guard let match = expression.firstMatch(in: prefix, range: full) else { return false }
		cursor = lineStart + match.range.location
		return true
	}

	private static func isHorizontalSpace(_ character: unichar) -> Bool {
		character == 0x20 || character == 0x09
	}

	private static func consumeLinkSuffix(cursor: inout Int, in text: NSString) -> Bool {
		guard cursor >= 0, cursor <= text.length,
		      2 <= text.length - cursor,
			  text.character(at: cursor) == 0x5D,
			  text.character(at: cursor + 1) == 0x28 else { return false }
		var scan = cursor + 2
		var nested = 0
		var escaped = false
		while scan < text.length {
			let character = text.character(at: scan)
			if escaped {
				escaped = false
			} else if character == 0x5C {
				escaped = true
			} else if character == 0x28 {
				nested += 1
			} else if character == 0x29 {
				if nested == 0 {
					cursor = scan + 1
					return true
				}
				nested -= 1
			} else if character == 0x0A || character == 0x0D {
				return false
			}
			scan += 1
		}
		return false
	}

	private static func contextMismatch(_ edit: Edit, in text: NSString) -> String? {
		let beforeLength = (edit.before as NSString).length
		if beforeLength > 0 {
			guard edit.start >= beforeLength,
				  plain(text.substring(with: NSRange(location: edit.start - beforeLength, length: beforeLength))) == plain(edit.before) else {
				return "before-context mismatch at \(edit.start): \(quoted(edit.before))"
			}
		}
		let afterLength = (edit.after as NSString).length
		if afterLength > 0 {
			guard edit.end <= text.length,
			      afterLength <= text.length - edit.end,
				  plain(text.substring(with: NSRange(location: edit.end, length: afterLength))) == plain(edit.after) else {
				return "after-context mismatch at \(edit.end): \(quoted(edit.after))"
			}
		}
		return nil
	}

	/// WebKit swaps spaces and non-breaking spaces inside contentEditable text
	/// at will (1:1 in UTF-16, so offsets are unaffected); verification must
	/// not read that churn as offset drift. The page normalizes its payloads
	/// the same way, but the source side can hold U+00A0 too.
	private static func plain(_ s: String) -> String {
		s.replacingOccurrences(of: "\u{00A0}", with: " ")
	}

	private static func quoted(_ s: String) -> String {
		"\"\(s.replacingOccurrences(of: "\n", with: "\\n"))\""
	}

	/// True when `offset` falls between the two halves of a UTF-16 surrogate
	/// pair — a position no splice boundary may ever occupy.
	private static func splitsSurrogatePair(_ text: NSString, at offset: Int) -> Bool {
		guard offset > 0, offset < text.length else { return false }
		return (0xD800...0xDBFF).contains(text.character(at: offset - 1))
			&& (0xDC00...0xDFFF).contains(text.character(at: offset))
	}
}

extension MarkdownEditSplicer.Edit {
	/// Parses the JS bridge's message body; nil when it isn't an edit message.
	init?(body: [String: Any]) {
		guard let start = body["start"] as? Int, let end = body["end"] as? Int else { return nil }
		self.start = start
		self.end = end
		self.wrapMarker = body["op"] as? String == "wrap" ? body["marker"] as? String : nil
		self.inlineCode = body["op"] as? String == "inlineCode"
		self.formatCommand = (body["op"] as? String == "format")
			? (body["command"] as? String).flatMap(MarkdownFormattingCommand.init(rawValue:))
			: nil
		self.replacement = body["text"] as? String
		self.expected = body["expected"] as? String ?? ""
		self.crossRun = body["crossRun"] as? Bool ?? false
		self.selected = body["selected"] as? Bool ?? false
		self.before = body["before"] as? String ?? ""
		self.after = body["after"] as? String ?? ""
		self.syntaxStart = body["syntaxStart"] as? [String] ?? []
		self.syntaxEnd = body["syntaxEnd"] as? [String] ?? []
		self.collapsedSyntaxEnd = body["collapsedSyntaxEnd"] as? [String] ?? []
		self.blockPrefixes = body["blockPrefixes"] as? [String] ?? []
		self.caret = body["caret"] as? Int
		self.listBreak = body["listBreak"] as? Bool ?? false
		self.blockStartBreak = body["blockStartBreak"] as? Bool ?? false
		self.endAtBlockStart = body["endAtBlockStart"] as? Bool ?? false
		self.hardBreak = body["hardBreak"] as? Bool ?? false
	}
}
