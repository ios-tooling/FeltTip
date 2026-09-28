//
//  MarkdownWebViewFindHost+MatchCount.swift
//  FeltTip
//
//  How many times the search term appears, shown next to the search field.
//

#if os(macOS)
	import AppKit
	import WebKit

	extension MarkdownWebViewFindHost {
		/// Count `term` in the rendered text and show the total.
		///
		/// The count comes from the page rather than from `WKFindResult`, which
		/// reports only whether *a* match was found. Counting `innerText` matches
		/// what the user is actually searching: the styled view hides the markdown
		/// syntax, so a search for `bold` should find the word inside `**bold**`
		/// and not the markers around it.
		///
		/// Only the total is shown, not "3 of 12". WebKit owns the traversal and
		/// its wrapping, so any index we kept alongside it would be our guess at
		/// its position, and would drift the first time the two disagreed.
		func updateMatchCount(for term: String) {
			guard !term.isEmpty else {
				matchCountLabel.stringValue = ""
				needsLayout = true
				return
			}
			let encoded = String(data: try! JSONEncoder().encode(term), encoding: .utf8) ?? "\"\""
			webView.evaluateJavaScript(Self.countScript(term: encoded)) { [weak self] result, _ in
				guard let self else { return }
				let count = (result as? NSNumber)?.intValue ?? 0
				matchCountLabel.stringValue = Self.label(for: count)
				needsLayout = true
			}
		}

		static func label(for count: Int) -> String {
			switch count {
			case 0: "No results"
			case 1: "1 result"
			default: "\(count) results"
			}
		}

		/// Non-overlapping, case-insensitive occurrences — the same matches a
		/// find would step through.
		private static func countScript(term: String) -> String {
			"""
			(function (needle) {
			  var hay = (document.body.innerText || '').toLowerCase();
			  needle = needle.toLowerCase();
			  if (!needle) { return 0; }
			  var count = 0, at = 0;
			  while ((at = hay.indexOf(needle, at)) !== -1) { count++; at += needle.length; }
			  return count;
			})(\(term))
			"""
		}
	}
#endif
