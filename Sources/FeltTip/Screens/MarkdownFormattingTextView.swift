//
//  MarkdownFormattingTextView.swift
//  MarkdownRendering
//

#if os(macOS)
import AppKit

public class MarkdownFormattingTextView: NSTextView {
	private var nativeReplaceControlProxy: NativeReplaceControlProxy?

	override public func performTextFinderAction(_ sender: Any?) {
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
			} else if let navigation = Self.findNavigationControl(
				in: self.window?.contentView) {
				navigation.setSelected(true, forSegment: 1)
				navigation.performClick(nil)
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

	private static func findNavigationControl(in view: NSView?) -> NSSegmentedControl? {
		guard let view else { return nil }
		if let control = view as? NSSegmentedControl,
		   control.segmentCount == 2,
		   control.label(forSegment: 0) == nil,
		   control.label(forSegment: 1) == nil {
			return control
		}
		return view.subviews.lazy.compactMap(findNavigationControl(in:)).first
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
