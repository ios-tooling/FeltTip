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
		/// Source offset to restore the caret to after a structural re-render;
		/// nil for in-place edits, which keep the browser's own caret.
		var caret: Int?
		/// The replacement is a list-item continuation ("\n- " / "\n1. ") the
		/// page composed from DOM structure. Only the source shows how deeply
		/// the item is indented, so the splice re-indents the new item to match
		/// the one being continued.
		var listBreak = false
	}

	enum Outcome {
		/// The new source, plus the selection to restore after a structural
		/// re-render: style toggles keep the (shifted) selection selected;
		/// other edits collapse to their caret target.
		case applied(String, selection: NSRange?)
		case rejected(String)
	}

	static func apply(_ edit: Edit, to source: String) -> Outcome {
		let text = source as NSString
		guard edit.start >= 0, edit.end >= edit.start, edit.end <= text.length else {
			return .rejected("out-of-bounds start=\(edit.start) end=\(edit.end) len=\(text.length)")
		}
		let range = NSRange(location: edit.start, length: edit.end - edit.start)
		let actual = text.substring(with: range)
		if !edit.crossRun, plain(actual) != plain(edit.expected) {
			return .rejected("expected mismatch range=\(range) expected=\(quoted(edit.expected)) actual=\(quoted(actual))")
		}
		if edit.crossRun, edit.wrapMarker == nil, edit.replacement?.isEmpty == true, !edit.selected,
		   actual.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted) != nil {
			return .rejected("collapsed cross-run delete would remove syntax \(quoted(actual))")
		}
		if let reason = contextMismatch(edit, in: text) {
			return .rejected(reason)
		}
		if let marker = edit.wrapMarker {
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
					return .applied(unwrapped, selection: NSRange(location: edit.start - length, length: edit.end - edit.start))
				}
			}
			let markerLength = (marker as NSString).length
			let wrapped = text.substring(to: edit.start) + marker + actual + marker + text.substring(from: edit.end)
			return .applied(wrapped, selection: NSRange(location: edit.start + markerLength, length: edit.end - edit.start))
		}
		guard var replacement = edit.replacement else {
			return .rejected("no replacement or marker")
		}
		var caret = edit.caret
		// Re-indent a list continuation to the item it continues; without this a
		// nested item's Enter produced a top-level item and reflowed the list.
		if edit.listBreak, replacement.hasPrefix("\n") {
			let indent = lineIndent(in: text, at: edit.start)
			if !indent.isEmpty {
				replacement = "\n" + indent + replacement.dropFirst()
				caret = caret.map { $0 + (indent as NSString).length }
			}
		}
		return .applied(text.replacingCharacters(in: range, with: replacement),
						selection: caret.map { NSRange(location: $0, length: 0) })
	}

	/// Leading whitespace of the line containing `offset`.
	private static func lineIndent(in text: NSString, at offset: Int) -> String {
		var lineStart = min(max(0, offset), text.length)
		while lineStart > 0, text.character(at: lineStart - 1) != 0x0A { lineStart -= 1 }
		var end = lineStart
		while end < text.length, text.character(at: end) == 0x20 || text.character(at: end) == 0x09 { end += 1 }
		return text.substring(with: NSRange(location: lineStart, length: end - lineStart))
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
			guard edit.end + afterLength <= text.length,
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
}

extension MarkdownEditSplicer.Edit {
	/// Parses the JS bridge's message body; nil when it isn't an edit message.
	init?(body: [String: Any]) {
		guard let start = body["start"] as? Int, let end = body["end"] as? Int else { return nil }
		self.start = start
		self.end = end
		self.wrapMarker = body["op"] as? String == "wrap" ? body["marker"] as? String : nil
		self.replacement = body["text"] as? String
		self.expected = body["expected"] as? String ?? ""
		self.crossRun = body["crossRun"] as? Bool ?? false
		self.selected = body["selected"] as? Bool ?? false
		self.before = body["before"] as? String ?? ""
		self.after = body["after"] as? String ?? ""
		self.caret = body["caret"] as? Int
		self.listBreak = body["listBreak"] as? Bool ?? false
	}
}
