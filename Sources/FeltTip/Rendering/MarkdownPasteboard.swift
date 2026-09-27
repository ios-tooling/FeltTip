//
//  MarkdownPasteboard.swift
//  FeltTip
//
//  The clipboard the edit bridge pastes from.
//

#if os(macOS)
	import AppKit
#else
	import UIKit
#endif

/// The clipboard the edit bridge reads a paste from, behind a seam the tests
/// can fill.
///
/// The seam exists because iOS refuses the read in a library test bundle. With
/// no UIApplication the process can't own a pasteboard write, so
/// `UIPasteboard.general.string` returns nil — "Operation not authorized" —
/// even for the string the test itself just wrote a line earlier. It fails
/// fast rather than hanging, so the paste path runs with nothing to splice and
/// every assertion downstream is meaningless. Without a substitute there is no
/// paste coverage on iOS at all.
///
/// Only tests set `substitute`. The app leaves it nil and reads the system
/// pasteboard, which is also what macOS does under test — a real `paste:`
/// through the responder chain is the pipeline those tests are there to cover.
enum MarkdownPasteboard {
	private static let sourceType = "com.standalone.marker.markdown-source"

	/// Stands in for the system pasteboard. Tests only; nil everywhere else.
	nonisolated(unsafe) static var substitute: (@Sendable () -> String?)?
	nonisolated(unsafe) static var sourceSubstitute: (@Sendable () -> String?)?
	nonisolated(unsafe) static var writeSourceSubstitute: (@Sendable (String) -> Void)?

	/// The clipboard's plain text, or nil when there is nothing pastable.
	static var text: String? {
		if let substitute { return substitute() }
		#if os(macOS)
			return NSPasteboard.general.string(forType: .string)
		#else
			return UIPasteboard.general.string
		#endif
	}

	/// Exact Markdown source carried alongside the rendered plain-text flavor.
	/// Other applications continue to see normal prose; another Marker editor
	/// can round-trip hidden syntax and block separators without loss.
	static var source: String? {
		if let sourceSubstitute { return sourceSubstitute() }
		#if os(macOS)
			guard let data = NSPasteboard.general.data(
				forType: NSPasteboard.PasteboardType(sourceType)) else { return nil }
		#else
			guard let data = UIPasteboard.general.data(
				forPasteboardType: sourceType) else { return nil }
		#endif
		return String(data: data, encoding: .utf8)
	}

	/// Adds the private source flavor only while the native cut's visible text
	/// is still on the pasteboard. The edit bridge message is asynchronous; an
	/// intervening Copy in this or another app must not receive stale Markdown.
	@discardableResult
	static func writeSource(_ source: String, ifTextMatches expectedText: String) -> Bool {
		guard text(text, matches: expectedText) else { return false }
		if let writeSourceSubstitute {
			writeSourceSubstitute(source)
			return true
		}
		let data = Data(source.utf8)
		#if os(macOS)
			NSPasteboard.general.setData(
				data, forType: NSPasteboard.PasteboardType(sourceType))
		#else
			UIPasteboard.general.setData(data, forPasteboardType: sourceType)
		#endif
		return true
	}

	/// WebKit's target range can omit whitespace at element boundaries while
	/// the native pasteboard inserts it. Permit those additions, but require
	/// every whitespace boundary the event did report so a later Copy with
	/// collapsed words cannot be mistaken for the original cut.
	private static func text(_ currentText: String?, matches expectedText: String) -> Bool {
		guard let currentText else { return false }
		let current = Array(currentText)
		let expected = Array(expectedText)
		if current.allSatisfy(\.isWhitespace), expected.allSatisfy(\.isWhitespace) {
			return true
		}

		var currentIndex = current.startIndex
		var expectedIndex = expected.startIndex
		while expectedIndex < expected.endIndex {
			if expected[expectedIndex].isWhitespace {
				guard currentIndex < current.endIndex,
					  current[currentIndex].isWhitespace else { return false }
				while currentIndex < current.endIndex, current[currentIndex].isWhitespace {
					currentIndex += 1
				}
				while expectedIndex < expected.endIndex, expected[expectedIndex].isWhitespace {
					expectedIndex += 1
				}
			} else {
				while currentIndex < current.endIndex, current[currentIndex].isWhitespace {
					currentIndex += 1
				}
				guard currentIndex < current.endIndex,
					  current[currentIndex] == expected[expectedIndex] else { return false }
				currentIndex += 1
				expectedIndex += 1
			}
		}
		return current[currentIndex...].allSatisfy(\.isWhitespace)
	}
}
