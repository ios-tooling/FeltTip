//
//  MarkdownPasteboard.swift
//  MarkDownRange
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
	/// Stands in for the system pasteboard. Tests only; nil everywhere else.
	nonisolated(unsafe) static var substitute: (@Sendable () -> String?)?

	/// The clipboard's plain text, or nil when there is nothing pastable.
	static var text: String? {
		if let substitute { return substitute() }
		#if os(macOS)
			return NSPasteboard.general.string(forType: .string)
		#else
			return UIPasteboard.general.string
		#endif
	}
}
