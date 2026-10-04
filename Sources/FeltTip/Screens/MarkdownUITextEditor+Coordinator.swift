//
//  MarkdownUITextEditor+Coordinator.swift
//  FeltTip
//
//  Delegate side of the iOS raw editor: edit reporting, caret/selection
//  restore, scroll-fraction sync, and highlight scheduling.
//

#if os(iOS)
import CrossPlatformKit
import SwiftUI
import UIKit

extension MarkdownUITextEditor {
	@MainActor final class Coordinator: NSObject, UITextViewDelegate {
		var parent: MarkdownUITextEditor
		let lineIndex = MarkdownLineIndex()
		/// Set while the coordinator itself is rewriting the view's text, so
		/// the resulting delegate callbacks don't get reported back to the host
		/// as user edits.
		private var isApplyingHostText = false
		private var lastCaretToken: Int?
		private var lastSelectionToken: Int?
		private var lastMirroredSelection: NSRange?
		private var lastSyncedFraction: Double?
		private var lastScrollTargetToken: Int?
		private var lastThemeSignature: Int?
		private var needsFullHighlight = true
		private var lastFocusRange: NSRange?
		private var lastFocusModeEnabled = false
		private var codeFenceRanges: [NSRange]?

		init(parent: MarkdownUITextEditor) {
			self.parent = parent
		}

		// MARK: - Host-driven text

		func replaceText(with text: String, in textView: UITextView) {
			isApplyingHostText = true
			defer { isApplyingHostText = false }
			let selected = textView.selectedRange
			textView.text = text
			lineIndex.rebuild(for: text)
			let length = (text as NSString).length
			textView.selectedRange = NSRange(
				location: min(selected.location, length), length: 0)
			invalidateHighlighting()
			highlight(textView, theme: parent.theme, enabled: parent.syntaxHighlightingEnabled)
			lastFocusRange = nil
		}

		// MARK: - UITextViewDelegate

		func textViewDidChange(_ textView: UITextView) {
			guard !isApplyingHostText else { return }
			let updated = textView.sourceString
			lineIndex.rebuild(for: updated)
			codeFenceRanges = nil
			if let onSourceEdit = parent.onSourceEdit {
				onSourceEdit(updated, textView.selectedRange.location)
			} else {
				parent.text = updated
			}
			highlight(textView, theme: parent.theme, enabled: parent.syntaxHighlightingEnabled)
			reportCursorPosition(in: textView)
			if parent.typewriterMode { centerCaret(in: textView) }
		}

		func textViewDidChangeSelection(_ textView: UITextView) {
			guard !isApplyingHostText else { return }
			reportCursorPosition(in: textView)
			let range = textView.selectedRange
			let reported: NSRange? = range.length > 0 ? range : nil
			parent.onSelectionChanged?(reported)
			parent.onSourceSelectionChanged?(reported)
			if parent.typewriterMode { centerCaret(in: textView) }
			applyFocusMode(to: textView)
		}

		func textViewDidBeginEditing(_ textView: UITextView) {
			applyFocusMode(to: textView)
		}

		func textViewDidEndEditing(_ textView: UITextView) {
			applyFocusMode(to: textView)
		}

		func scrollViewDidScroll(_ scrollView: UIScrollView) {
			guard let onScrollFractionChanged = parent.onScrollFractionChanged else { return }
			let span = scrollView.contentSize.height - scrollView.bounds.height
			guard span > 0 else { return }
			let fraction = min(max(0, scrollView.contentOffset.y / span), 1)
			// Don't echo a fraction we just applied from the other pane.
			guard lastSyncedFraction.map({ abs($0 - fraction) > 0.0001 }) ?? true else { return }
			onScrollFractionChanged(Double(fraction))
		}

		// MARK: - Host-driven restores

		func applyCaretTarget(to textView: UITextView) {
			guard let target = parent.caretTarget, target.token != lastCaretToken else { return }
			lastCaretToken = target.token
			let length = (textView.sourceString as NSString).length
			let clamped = min(max(0, target.offset), length)
			textView.selectedRange = NSRange(location: clamped, length: 0)
			textView.scrollRangeToVisible(textView.selectedRange)
		}

		func applySelectionTarget(to textView: UITextView) {
			guard let target = parent.selectionTarget, target.token != lastSelectionToken else { return }
			lastSelectionToken = target.token
			let length = (textView.sourceString as NSString).length
			let location = min(max(0, target.range.location), length)
			let selected = min(max(0, target.range.length), length - location)
			textView.selectedRange = NSRange(location: location, length: selected)
			textView.scrollRangeToVisible(textView.selectedRange)
		}

		/// The other pane's selection, drawn as an inactive wash. Goes through
		/// the highlight sink, which on iOS means a storage attribute — see
		/// MarkdownHighlightSink for why there's no temporary-attribute option.
		func applyMirroredSelection(to textView: UITextView) {
			guard lastMirroredSelection != parent.mirroredSelection else { return }
			guard let sink = textView.highlightSink else { return }
			let full = NSRange(location: 0, length: (textView.sourceString as NSString).length)
			if let previous = lastMirroredSelection, previous.length > 0 {
				sink.clearBackground(in: full)
			}
			lastMirroredSelection = parent.mirroredSelection
			guard let range = parent.mirroredSelection, range.length > 0,
			      NSMaxRange(range) <= full.length,
			      let wash = parent.theme?.mirrorHighlightColor else { return }
			sink.setBackground(UXColor(wash), in: range)
		}

		func applySyncScrollFraction(to textView: UITextView) {
			guard let fraction = parent.syncScrollFraction,
			      lastSyncedFraction.map({ abs($0 - fraction) > 0.0001 }) ?? true else { return }
			lastSyncedFraction = fraction
			let span = textView.contentSize.height - textView.bounds.height
			guard span > 0 else { return }
			textView.setContentOffset(
				CGPoint(x: 0, y: CGFloat(fraction) * span), animated: false)
		}

		func applyScrollTarget(to textView: UITextView) {
			guard let target = parent.scrollTarget,
			      target.token != lastScrollTargetToken else { return }
			lastScrollTargetToken = target.token
			let span = textView.contentSize.height - textView.bounds.height
			guard span > 0 else { return }
			textView.setContentOffset(
				CGPoint(x: 0, y: target.topFraction * span), animated: false)
		}

		// MARK: - Appearance

		func applyTheme(to textView: UITextView, theme: MarkdownTheme?) {
			let signature = theme?.signature
			guard lastThemeSignature != signature?.hashValue else { return }
			lastThemeSignature = signature?.hashValue
			textView.backgroundColor = UXColor(theme?.backgroundColor ?? MarkdownTheme.defaultBackgroundColor)
			textView.textColor = UXColor(theme?.textColor ?? .primary)
			textView.tintColor = UXColor(theme?.linkColor ?? .accentColor)
			invalidateHighlighting()
		}

		// MARK: - Highlighting

		func invalidateHighlighting() {
			needsFullHighlight = true
			codeFenceRanges = nil
		}

		func highlightIfNeeded(_ textView: UITextView, theme: MarkdownTheme?, enabled: Bool) {
			guard needsFullHighlight else { return }
			highlight(textView, theme: theme, enabled: enabled)
		}

		func highlight(_ textView: UITextView, theme: MarkdownTheme?, enabled: Bool) {
			needsFullHighlight = false
			guard enabled, let theme else {
				MarkdownSyntaxHighlighter.clearHighlighting(textView: textView, theme: theme)
				return
			}
			MarkdownSyntaxHighlighter.highlight(textView: textView, theme: theme)
		}

		func applyFocusMode(to textView: UITextView) {
			let shouldFocus = parent.focusModeEnabled && textView.isFirstResponder
			let nextRange = shouldFocus
				? MarkdownFocusMode.focusedRange(in: textView.sourceString, selection: textView.selectedRange)
				: nil
			guard lastFocusRange != nextRange || lastFocusModeEnabled != shouldFocus else { return }
			highlight(textView, theme: parent.theme, enabled: parent.syntaxHighlightingEnabled)
			lastFocusRange = nextRange
			lastFocusModeEnabled = shouldFocus
			guard shouldFocus, let nextRange, let sink = textView.highlightSink else { return }
			let full = NSRange(location: 0, length: (textView.sourceString as NSString).length)
			guard full.length > 0 else { return }
			sink.setColor(UXColor(parent.theme?.textColor ?? .primary).withAlphaComponent(0.3), in: full)
			sink.setColor(UXColor(parent.theme?.textColor ?? .primary), in: nextRange)
		}

		// MARK: - Reporting

		private func reportCursorPosition(in textView: UITextView) {
			guard let report = parent.onCursorPositionChanged else { return }
			let range = textView.selectedRange
			let position = lineIndex.position(at: range.location)
			report(position.line, position.column, range.length, range.location)
		}

		/// Typewriter scrolling with a dead band — the same shape as the macOS
		/// editor's. Hard-snapping the caret line to center on every keystroke
		/// reads as constant jitter, so this only recenters once the caret has
		/// drifted out of the comfortable middle band.
		private func centerCaret(in textView: UITextView) {
			let caret = textView.caretRect(for: textView.selectedTextRange?.start
				?? textView.beginningOfDocument)
			guard caret.height > 0, caret.origin.y.isFinite else { return }
			let visibleHeight = textView.bounds.height
			guard visibleHeight > 0 else { return }
			let band = visibleHeight / 4
			let caretY = caret.midY - textView.contentOffset.y
			guard caretY < band || caretY > visibleHeight - band else { return }
			let span = textView.contentSize.height - visibleHeight
			guard span > 0 else { return }
			let target = min(max(0, caret.midY - visibleHeight / 2), span)
			textView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
		}
	}
}
#endif
