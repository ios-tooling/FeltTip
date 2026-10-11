//
//  MarkdownFormattingTextView.swift
//  MarkdownRendering
//

#if os(macOS)
import AppKit

public class MarkdownFormattingTextView: NSTextView {
	private var nativeReplaceControlProxy: NativeReplaceControlProxy?
	/// Called after the text view scrolls itself — revealing a moved caret
	/// (⌘↓, page down, typing past the edge, a find match). The raw editor
	/// adopts the result as its viewport anchor right away; waiting for the
	/// selection notification lost a race with TextKit 2's layout-driven
	/// geometry replay, which snapped ⌘↓ in a large document back to the top.
	///
	/// Only scrolls made while handling the user's input count. AppKit also
	/// scrolls the text view to its caret on its own (on focus changes and
	/// while laying out), and adopting those snapped a restored viewport back
	/// to the top.
	var onSelfScroll: (() -> Void)?
	private var userInputDepth = 0

	private func handlingUserInput<T>(_ body: () -> T) -> T {
		userInputDepth += 1
		defer { userInputDepth -= 1 }
		return body()
	}

	private func noteSelfScroll() {
		guard userInputDepth > 0 else { return }
		onSelfScroll?()
	}

	override public func keyDown(with event: NSEvent) { handlingUserInput { super.keyDown(with: event) } }
	override public func mouseDown(with event: NSEvent) { handlingUserInput { super.mouseDown(with: event) } }
	override public func doCommand(by selector: Selector) { handlingUserInput { super.doCommand(by: selector) } }
	override public func insertText(_ string: Any, replacementRange: NSRange) {
		handlingUserInput { super.insertText(string, replacementRange: replacementRange) }
	}

	override public func scrollRangeToVisible(_ range: NSRange) {
		super.scrollRangeToVisible(range)
		noteSelfScroll()
	}

	override public func scrollToVisible(_ rect: NSRect) -> Bool {
		let scrolled = super.scrollToVisible(rect)
		if scrolled { noteSelfScroll() }
		return scrolled
	}

	override public func scroll(_ point: NSPoint) {
		super.scroll(point)
		noteSelfScroll()
	}

	// MARK: Paging on TextKit 2

	// On a TextKit 2 view AppKit's `pageDown:` moves the insertion point to
	// the end of the document without scrolling, and `pageUp:` mirrors it.
	// (The Page Down key itself is bound to `scrollPageDown:`, which works.)
	// Page by the visible height instead, keeping the caret at the same place
	// on screen, as the TextKit 1 view did.

	override public func pageDown(_ sender: Any?) {
		guard textLayoutManager != nil else { return super.pageDown(sender) }
		page(down: true, extending: false)
	}

	override public func pageUp(_ sender: Any?) {
		guard textLayoutManager != nil else { return super.pageUp(sender) }
		page(down: false, extending: false)
	}

	override public func pageDownAndModifySelection(_ sender: Any?) {
		guard textLayoutManager != nil else { return super.pageDownAndModifySelection(sender) }
		page(down: true, extending: true)
	}

	override public func pageUpAndModifySelection(_ sender: Any?) {
		guard textLayoutManager != nil else { return super.pageUpAndModifySelection(sender) }
		page(down: false, extending: true)
	}

	// MARK: Document jumps on TextKit 2

	// AppKit's ⌘↓ on a TextKit 2 view reveals the end through its own
	// scrolling, which can lay out the whole document first: about 3 s on a
	// 20 MB file in the default font and 14 s in SF Mono 13, on a plain
	// NSTextView with none of this editor's code. Move the caret, then reveal
	// it from the end's own layout fragment, which lays out only that
	// fragment; the viewport lays out the rest of the screen as it draws.

	override public func moveToEndOfDocument(_ sender: Any?) {
		guard textLayoutManager != nil else { return super.moveToEndOfDocument(sender) }
		jump(toEnd: true, extending: false)
	}

	override public func moveToBeginningOfDocument(_ sender: Any?) {
		guard textLayoutManager != nil else { return super.moveToBeginningOfDocument(sender) }
		jump(toEnd: false, extending: false)
	}

	override public func moveToEndOfDocumentAndModifySelection(_ sender: Any?) {
		guard textLayoutManager != nil else { return super.moveToEndOfDocumentAndModifySelection(sender) }
		jump(toEnd: true, extending: true)
	}

	override public func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) {
		guard textLayoutManager != nil else { return super.moveToBeginningOfDocumentAndModifySelection(sender) }
		jump(toEnd: false, extending: true)
	}

	private func jump(toEnd: Bool, extending: Bool) {
		let length = textStorage?.length ?? 0
		let selection = selectedRange()
		let target = toEnd ? length : 0
		if extending {
			let anchor = toEnd ? selection.location : NSMaxRange(selection)
			setSelectedRange(NSRange(location: min(anchor, target), length: abs(target - anchor)))
		} else {
			setSelectedRange(NSRange(location: target, length: 0))
		}
		guard let scrollView = enclosingScrollView, let documentView = scrollView.documentView else { return }
		let clip = scrollView.contentView
		let minY = documentView.frame.minY
		var y = minY
		if toEnd, let line = sourceLineRect(atCharacterOffset: length) {
			let bottom = convert(line, to: clip).maxY + textContainerInset.height
			y = bottom - clip.bounds.height
		}
		let maxY = max(minY, documentView.frame.maxY - clip.bounds.height)
		clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(maxY, max(minY, y))))
		scrollView.reflectScrolledClipView(clip)
		layOutViewportAfterJump()
		if !viewportShows(characterOffset: toEnd ? max(0, length - 1) : 0) {
			relocateViewport(toEnd: toEnd, in: scrollView)
		}
		onSelfScroll?()
	}

	/// Whether the laid-out viewport includes the character at `offset`.
	private func viewportShows(characterOffset offset: Int) -> Bool {
		guard let manager = textLayoutManager, let content = manager.textContentManager,
			  let viewport = manager.textViewportLayoutController.viewportRange else { return false }
		let start = content.characterOffset(of: viewport.location)
		let end = content.characterOffset(of: viewport.endLocation)
		return offset >= start && offset <= end
	}

	/// The fallback when the fragment's estimated position and the viewport's
	/// mapping of scroll offsets disagree, which happens on very tall
	/// documents (about 19.5 MB of short Markdown lines and up): jumping to
	/// the estimate leaves a blank viewport, the original #27 symptom.
	/// `relocateViewport(to:)` re-anchors TextKit's estimates on the target.
	/// It costs time proportional to the document (about 4 s at 20 MB, against
	/// 14 s for AppKit's own ⌘↓ there), so it is only the fallback.
	private func relocateViewport(toEnd: Bool, in scrollView: NSScrollView) {
		guard let manager = textLayoutManager else { return }
		let target = toEnd ? manager.documentRange.endLocation : manager.documentRange.location
		let offset = manager.textViewportLayoutController.relocateViewport(to: target)
		let clip = scrollView.contentView
		guard let documentView = scrollView.documentView else { return }
		let minY = documentView.frame.minY
		let maxY = max(minY, documentView.frame.maxY - clip.bounds.height)
		let y = toEnd ? maxY : min(maxY, max(minY, offset))
		clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
		scrollView.reflectScrolledClipView(clip)
		layOutViewportAfterJump()
	}

	/// After a programmatic jump deep into estimated territory, TextKit 2 can
	/// leave the new viewport unlaid — a correct caret over a blank view
	/// (issue #27). Ask the viewport controller to lay out where we now are.
	func layOutViewportAfterJump() {
		textLayoutManager?.textViewportLayoutController.layoutViewport()
		needsDisplay = true
		enclosingScrollView?.verticalRulerView?.needsDisplay = true
	}

	private func page(down: Bool, extending: Bool) {
		guard let scrollView = enclosingScrollView, let documentView = scrollView.documentView else { return }
		let clip = scrollView.contentView
		let length = textStorage?.length ?? 0
		let selection = selectedRange()
		// The end that moves: the caret, or the far end of an extending selection.
		let moving = extending && down ? NSMaxRange(selection) : selection.location
		let lineHeight = sourceLineRect(atCharacterOffset: moving)?.height ?? (font?.pointSize ?? 13) * 1.3
		let page = max(lineHeight, clip.bounds.height - lineHeight)
		let delta = down ? page : -page

		let caretInClip = sourceLineRect(atCharacterOffset: moving).map { convert($0, to: clip) }
		let minY = documentView.frame.minY
		let maxY = max(minY, documentView.frame.maxY - clip.bounds.height)
		let newY = min(maxY, max(minY, clip.bounds.minY + delta))
		let moved = newY - clip.bounds.minY
		clip.scroll(to: NSPoint(x: clip.bounds.minX, y: newY))
		scrollView.reflectScrolledClipView(clip)
		layOutViewportAfterJump()
		onSelfScroll?()

		var target: Int
		if abs(moved) < abs(delta) - 0.5 {
			// The view hit an end before a full page: so does the caret.
			target = down ? length : 0
		} else if let caretInClip {
			let point = convert(
				CGPoint(x: caretInClip.minX + 1, y: caretInClip.midY + moved), from: clip)
			target = sourceCharacterOffset(at: point) ?? moving
		} else {
			target = moving
		}
		target = min(max(0, target), length)
		if extending {
			let anchor = down ? selection.location : NSMaxRange(selection)
			setSelectedRange(NSRange(location: min(anchor, target), length: abs(target - anchor)))
		} else {
			setSelectedRange(NSRange(location: target, length: 0))
		}
	}

	override public func performTextFinderAction(_ sender: Any?) {
		handlingUserInput { performTextFinderActionHandlingInput(sender) }
	}

	private func performTextFinderActionHandlingInput(_ sender: Any?) {
		let action = (sender as? NSMenuItem).flatMap {
			NSTextFinder.Action(rawValue: $0.tag)
		}
		if action == .replace || action == .replaceAndFind {
			selectRememberedFindMatchIfNeeded()
		}
		super.performTextFinderAction(sender)
		guard action == .showFindInterface || action == .showReplaceInterface else { return }
		// AppKit often mounts the native find bar synchronously. Install the
		// replacement guard before returning so an immediately clicked Replace
		// button cannot beat the asynchronous monitor below and insert at a stale
		// caret instead of the remembered match.
		installNativeReplaceControlProxyIfAvailable()

		// AppKit remembers a hidden find bar's current result independently of
		// NSTextView's selection. If a host-driven undo restores the source while
		// the bar is closed, reopening Find can therefore show a valid result
		// count with only an insertion point in the editor. Pressing Replace in
		// that state inserts the replacement before the match ("reviewdraft")
		// instead of replacing it. Reacquire the remembered query once the native
		// bar has mounted, but leave a selection AppKit restored on its own alone.
		reacquireRememberedFindMatch(attempt: 0, navigationAttempts: 0)
	}

	private func reacquireRememberedFindMatch(
		attempt: Int,
		navigationAttempts: Int
	) {
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
			guard let self else { return }
			guard self.enclosingScrollView?.isFindBarVisible == true else {
				if attempt < 20 {
					self.reacquireRememberedFindMatch(
						attempt: attempt + 1,
						navigationAttempts: navigationAttempts)
				}
				return
			}
			guard self.selectedRange().length == 0 else { return }
			guard let searchField = Self.findSearchField(in: self.window?.contentView) else {
				if attempt < 20 {
					self.reacquireRememberedFindMatch(
						attempt: attempt + 1,
						navigationAttempts: navigationAttempts)
				}
				return
			}
			guard !searchField.stringValue.isEmpty else {
				if attempt < 20 {
					self.reacquireRememberedFindMatch(
						attempt: attempt + 1,
						navigationAttempts: navigationAttempts)
				}
				return
			}
			if navigationAttempts == 0 {
				let previousResponder = self.window?.firstResponder
				self.window?.makeFirstResponder(self)
				let next = NSMenuItem()
				next.tag = NSTextFinder.Action.nextMatch.rawValue
				self.performTextFinderAction(next)
				if previousResponder !== self {
					self.window?.makeFirstResponder(previousResponder)
				}
			} else {
				Self.performNextMatch(on: self)
			}
			// A stale finder can consume the first navigation solely to refresh
			// its current-result state. Retry once if no range was established.
			if navigationAttempts == 0 {
				self.reacquireRememberedFindMatch(
					attempt: attempt + 1,
					navigationAttempts: 1)
			}
		}
		monitorNativeReplaceControl()
	}

	private func monitorNativeReplaceControl(after delay: TimeInterval = 0.05) {
		DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
			guard let self else { return }
			guard self.enclosingScrollView?.isFindBarVisible == true else {
				self.nativeReplaceControlProxy = nil
				return
			}
			self.installNativeReplaceControlProxyIfAvailable()
			self.monitorNativeReplaceControl(after: 0.25)
		}
	}

	private func installNativeReplaceControlProxyIfAvailable() {
		let control = Self.findReplaceControl(in: window?.contentView)
		if nativeReplaceControlProxy?.control !== control {
			nativeReplaceControlProxy = nil
		}
		guard nativeReplaceControlProxy == nil, let control else { return }
		let proxy = NativeReplaceControlProxy(
			editor: self,
			control: control,
			originalTarget: control.target,
			originalAction: control.action)
		nativeReplaceControlProxy = proxy
		control.target = proxy
		control.action = #selector(NativeReplaceControlProxy.performAction(_:))
	}

	private static func findSearchField(in view: NSView?) -> NSSearchField? {
		guard let view else { return nil }
		if let field = view as? NSSearchField { return field }
		return view.subviews.lazy.compactMap(findSearchField(in:)).first
	}

	fileprivate func selectRememberedFindMatchIfNeeded() {
		guard selectedRange().length == 0,
		      let query = Self.findSearchField(in: window?.contentView)?.stringValue,
		      !query.isEmpty else { return }
		let source = string as NSString
		let start = min(selectedRange().location, source.length)
		let tail = NSRange(location: start, length: source.length - start)
		var match = source.range(of: query, options: [], range: tail)
		if match.location == NSNotFound, start > 0 {
			match = source.range(of: query, options: [], range: NSRange(location: 0, length: start))
		}
		if match.location == NSNotFound {
			match = source.range(of: query, options: [.caseInsensitive])
		}
		guard match.location != NSNotFound else { return }
		setSelectedRange(match)
	}

	fileprivate func replaceSelectedFindMatch(with replacement: String) {
		let match = selectedRange()
		guard match.length > 0 else { return }
		textStorage?.replaceCharacters(in: match, with: replacement)
		didChangeText()
		setSelectedRange(NSRange(
			location: match.location + (replacement as NSString).length,
			length: 0))
	}

	fileprivate static func findReplaceField(in view: NSView?) -> NSTextField? {
		guard let view else { return nil }
		if let field = view as? NSTextField,
		   !(field is NSSearchField),
		   field.isEditable {
			return field
		}
		return view.subviews.lazy.compactMap(findReplaceField(in:)).first
	}

	private static func findReplaceControl(in view: NSView?) -> NSSegmentedControl? {
		guard let view, let field = findReplaceField(in: view) else { return nil }
		let fieldMidY = field.convert(field.bounds, to: nil).midY
		return segmentedControls(in: view).min {
			abs($0.convert($0.bounds, to: nil).midY - fieldMidY) <
				abs($1.convert($1.bounds, to: nil).midY - fieldMidY)
		}
	}

	private static func segmentedControls(in view: NSView) -> [NSSegmentedControl] {
		var matches = view.subviews.flatMap(segmentedControls(in:))
		if let control = view as? NSSegmentedControl, control.segmentCount == 2 {
			matches.insert(control, at: 0)
		}
		return matches
	}

	/// Advance the open find bar to its next match through the text view's
	/// own finder action. Never `performClick` the bar's Next control:
	/// NSSegmentedCell's click queues a CFRunLoopStop block on the main run
	/// loop for its own nested event loop to consume, and when that loop
	/// returns early the block is left behind. The next time the main loop
	/// runs it stops — in a host whose main loop is Swift's concurrency drain
	/// (the test runner) that exits the process mid-run, and in the app it
	/// pumps events in the middle of a SwiftUI update. Delivering the bar's
	/// action directly does nothing; the finder only navigates through this.
	static func performNextMatch(on textView: NSTextView) {
		let next = NSMenuItem()
		next.tag = NSTextFinder.Action.nextMatch.rawValue
		textView.performTextFinderAction(next)
	}


	override public func becomeFirstResponder() -> Bool {
		let accepted = super.becomeFirstResponder()
		if accepted, let coordinator = delegate as? MarkdownTextEditor.Coordinator {
			// Becoming the active pane: report the current selection right
			// away so the host clears this pane's now-stale mirror.
			coordinator.reportSelectionOnFocus(self)
		}
		return accepted
	}

	override public func resignFirstResponder() -> Bool {
		let resigned = super.resignFirstResponder()
		if resigned, let coordinator = delegate as? MarkdownTextEditor.Coordinator {
			coordinator.reportFocusLoss(self)
		}
		return resigned
	}

	override public func performKeyEquivalent(with event: NSEvent) -> Bool {
		// Only when this editor is focused: performKeyEquivalent visits every
		// view in the window, and in a split the raw pane was consuming the
		// ⌘B/⌘I aimed at the styled pane, applying them to its own selection.
		guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
		let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
		switch (event.charactersIgnoringModifiers?.lowercased() ?? "", mods) {
		case ("b", [.command]): applyFormatting(.bold); return true
		case ("i", [.command]): applyFormatting(.italic); return true
		case ("u", [.command]): applyFormatting(.underline); return true
		case ("k", [.command]): applyFormatting(.link); return true
		case ("=", [.command, .option]): applyFormatting(.increaseHeading); return true
		case ("-", [.command, .option]): applyFormatting(.decreaseHeading); return true
		case ("6", [.command, .shift]): applyFormatting(.superscript); return true
		case ("-", [.command, .shift]): applyFormatting(.subscriptText); return true
		case ("x", [.command, .shift]):
			applyFormatting(.strikethrough); return true
		case ("\r", _), ("\u{3}", _): return false
		default: return super.performKeyEquivalent(with: event)
		}
	}

	/// Menu-item entry points, matching the key equivalents above.
	public func toggleBold() { applyFormatting(.bold) }
	public func toggleItalic() { applyFormatting(.italic) }
	public func toggleStrikethrough() { applyFormatting(.strikethrough) }
	public func toggleCode() { applyFormatting(.inlineCode) }

	public func applyFormatting(_ command: MarkdownFormattingCommand) {
		guard let change = MarkdownSourceFormatter.change(
			in: string,
			selection: selectedRange(),
			command: command) else { return }
		applyChange(
			in: change.range,
			with: change.replacement,
			cursor: change.rawSelection ?? change.selection)
	}

	private func applyChange(in range: NSRange, with text: String, cursor: NSRange) {
		guard shouldChangeText(in: range, replacementString: text) else { return }
		textStorage?.replaceCharacters(in: range, with: text)
		didChangeText()
		setSelectedRange(cursor)
	}
}

@MainActor
final class NativeReplaceControlProxy: NSObject {
	private weak var editor: MarkdownFormattingTextView?
	fileprivate weak var control: NSSegmentedControl?
	private var originalTarget: AnyObject?
	private let originalAction: Selector?

	init(
		editor: MarkdownFormattingTextView,
		control: NSSegmentedControl,
		originalTarget: AnyObject?,
		originalAction: Selector?
	) {
		self.editor = editor
		self.control = control
		self.originalTarget = originalTarget
		self.originalAction = originalAction
	}

	@objc func performAction(_ sender: Any?) {
		guard control?.selectedSegment != 1 else {
			forwardOriginalAction()
			return
		}
		guard let editor,
		      let replacement = MarkdownFormattingTextView.findReplaceField(
			in: editor.window?.contentView)?.stringValue else {
			forwardOriginalAction()
			return
		}
		editor.selectRememberedFindMatchIfNeeded()
		let match = editor.selectedRange()
		guard match.length > 0 else {
			forwardOriginalAction()
			return
		}
		// NSTextView.insertText and shouldChangeText both ask NSTextFinder to
		// synchronously stop its asynchronous search before editing. Under load
		// that wait can deadlock the main thread, so mutate the already-validated
		// match and then send the ordinary did-change notification ourselves.
		editor.replaceSelectedFindMatch(with: replacement)
		editor.selectRememberedFindMatchIfNeeded()
	}

	private func forwardOriginalAction() {
		guard let originalAction, let control else { return }
		// AppKit uses the segmented control sender to distinguish Replace from
		// Replace All. Forwarding nil makes the native target silently ignore the
		// All segment even though the button visibly presses.
		NSApp.sendAction(originalAction, to: originalTarget, from: control)
	}
}
#endif
