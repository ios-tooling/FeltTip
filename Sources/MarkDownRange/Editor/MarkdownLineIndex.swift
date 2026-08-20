//
//  MarkdownLineIndex.swift
//  MarkDownRange
//
//  Extracted from MarkdownTextEditor so the iOS raw editor can share the same
//  cursor-position reporting. Pure Foundation — no platform dependency.
//

import Foundation

/// Incremental UTF-16 line index shared by cursor reporting. Character edits
/// remove only starts inside the replaced span, shift the surviving suffix,
/// and insert newly-created starts in their already-sorted position. This
/// avoids allocating and sorting the entire line table for every keystroke.
final class MarkdownLineIndex {
	private(set) var starts: [Int] = [0]

	init(text: String = "") {
		rebuild(for: text)
	}

	func rebuild(for text: String) {
		starts = [0]
		var offset = 0
		for unit in text.utf16 {
			offset += 1
			if unit == 0x0A { starts.append(offset) }
		}
	}

	func applyEdit(in text: NSString, editedRange: NSRange, delta: Int) {
		guard editedRange.location >= 0, editedRange.location <= text.length,
		      editedRange.length >= 0, NSMaxRange(editedRange) <= text.length else {
			rebuild(for: text as String)
			return
		}
		let oldLength = max(0, editedRange.length - delta)
		let oldEnd = editedRange.location + oldLength
		let firstAffected = upperBound(of: editedRange.location)
		let afterRemoved = upperBound(of: oldEnd)
		if firstAffected < afterRemoved {
			starts.removeSubrange(firstAffected..<afterRemoved)
		}
		if delta != 0, firstAffected < starts.count {
			for index in firstAffected..<starts.count {
				starts[index] += delta
			}
		}
		var inserted: [Int] = []
		for index in editedRange.location..<NSMaxRange(editedRange)
		where text.character(at: index) == 0x0A {
			inserted.append(index + 1)
		}
		if !inserted.isEmpty {
			starts.insert(contentsOf: inserted, at: firstAffected)
		}
	}

	func position(at offset: Int) -> (line: Int, column: Int) {
		let clamped = max(0, offset)
		let index = max(0, upperBound(of: clamped) - 1)
		return (index + 1, clamped - starts[index] + 1)
	}

	private func upperBound(of value: Int) -> Int {
		var low = 0
		var high = starts.count
		while low < high {
			let mid = (low + high) / 2
			if starts[mid] <= value { low = mid + 1 } else { high = mid }
		}
		return low
	}
}
