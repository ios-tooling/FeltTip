//
//  MarkdownTextEditor.swift
//  MarkdownRendering
//

#if os(macOS)
import SwiftUI
import AppKit

public struct MarkdownTextEditor: NSViewRepresentable {
	@Binding var text: String
	@Binding var selectedHeadingID: String?
	@Environment(\.showLineNumbers) var showLineNumbers
	@Environment(\.syntaxHighlightingEnabled) var syntaxHighlightingEnabled
	@Environment(\.markdownOptions) var markdownOptions
	@Environment(\.markdownLineChanges) var lineChanges
	var fontSize: CGFloat = 13
	var onVisibleHeadingChanged: ((String?) -> Void)?
	var onScrollFractionChanged: ((Double) -> Void)?
	var syncScrollFraction: Double?
	var typewriterMode: Bool = false
	var theme: MarkdownTheme?
	var onCursorPositionChanged: ((Int, Int, Int, Int) -> Void)?
	/// When set, edits are reported here — with the post-edit caret offset —
	/// INSTEAD of being written to the `text` binding, so a host tracking undo
	/// state can record the caret alongside the new text. The host must feed
	/// the new text back through the binding's backing store.
	var onSourceEdit: ((String, Int) -> Void)?
	/// Reports the selected source range whenever this (focused) editor's
	/// selection changes; nil for a collapsed selection. Feeds the split
	/// view's cross-pane selection mirroring.
	var onSelectionChanged: ((NSRange?) -> Void)?
	/// A selection made in the OTHER pane, shown here as an inactive-selection
	/// highlight (temporary layout attributes — the real selection, text
	/// storage, and undo state are untouched).
	var mirroredSelection: NSRange?
	var scrollToCharacterOffset: Int?
	var caretTarget: MarkdownCaretTarget?

	public init(
		text: Binding<String>,
		selectedHeadingID: Binding<String?>,
		fontSize: CGFloat = 13,
		onVisibleHeadingChanged: ((String?) -> Void)? = nil,
		onScrollFractionChanged: ((Double) -> Void)? = nil,
		syncScrollFraction: Double? = nil,
		typewriterMode: Bool = false,
		theme: MarkdownTheme? = nil,
		onCursorPositionChanged: ((Int, Int, Int, Int) -> Void)? = nil,
		onSourceEdit: ((String, Int) -> Void)? = nil,
		onSelectionChanged: ((NSRange?) -> Void)? = nil,
		mirroredSelection: NSRange? = nil,
		scrollToCharacterOffset: Int? = nil,
		caretTarget: MarkdownCaretTarget? = nil
	) {
		self._text = text
		self._selectedHeadingID = selectedHeadingID
		self.fontSize = fontSize
		self.onVisibleHeadingChanged = onVisibleHeadingChanged
		self.onScrollFractionChanged = onScrollFractionChanged
		self.syncScrollFraction = syncScrollFraction
		self.typewriterMode = typewriterMode
		self.theme = theme
		self.onCursorPositionChanged = onCursorPositionChanged
		self.onSourceEdit = onSourceEdit
		self.onSelectionChanged = onSelectionChanged
		self.mirroredSelection = mirroredSelection
		self.scrollToCharacterOffset = scrollToCharacterOffset
		self.caretTarget = caretTarget
	}

	public func makeNSView(context: Context) -> NSScrollView {
		let scrollView = RulerInsetScrollView()
		let textView = MarkdownFormattingTextView()
		scrollView.setAccessibilityIdentifier("raw-markdown-scroll-view")
		textView.setAccessibilityIdentifier("raw-markdown-editor")

		textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
		context.coordinator.lastAppliedFontSize = fontSize
		textView.isEditable = true
		textView.isRichText = false
		textView.allowsUndo = true
		textView.delegate = context.coordinator
		textView.isVerticallyResizable = true
		textView.isHorizontallyResizable = false
		textView.autoresizingMask = [.width]
		textView.textContainerInset = NSSize(width: 8, height: 8)
		textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
		textView.textContainer?.widthTracksTextView = true
		textView.usesFindBar = true
		textView.isIncrementalSearchingEnabled = true
		textView.string = text
		context.coordinator.scheduleIncrementalLayout(for: textView)
		// Wire the textStorage delegate so the coordinator can capture the
		// edited range — the incremental highlight path needs it to scope
		// re-styling to the paragraph that actually changed.
		textView.textStorage?.delegate = context.coordinator

		scrollView.documentView = textView
		scrollView.hasVerticalScroller = true
		scrollView.hasHorizontalScroller = false
		// Text wraps to the view width, so there's nothing to scroll to
		// horizontally; disable the elastic horizontal overscroll so the pane
		// only moves up and down.
		scrollView.horizontalScrollElasticity = .none
		scrollView.autohidesScrollers = true
		scrollView.contentView.postsBoundsChangedNotifications = true
		applyTheme(to: textView, scrollView: scrollView, coordinator: context.coordinator)
		updateRuler(scrollView: scrollView, textView: textView)
		updateHighlighting(textView: textView)

		context.coordinator.scrollObserver = NotificationCenter.default.addObserver(
			forName: NSView.boundsDidChangeNotification,
			object: scrollView.contentView,
			queue: .main
		) { [weak scrollView, weak textView, weak coordinator = context.coordinator] _ in
			guard let scrollView, let coordinator, !coordinator.isSyncScroll else { return }

			// Coalesce ALL reactions — including the ruler invalidation — to
			// the end of the runloop turn, and read the SETTLED offset.
			// Reacting synchronously to every bounds notification fed a
			// self-sustaining retile loop (invalidate → tile → bounds change →
			// invalidate …) that stormed at millisecond cadence and eroded the
			// user's scroll position; transient origins (e.g. 9 → 0 → 7.5 in
			// one turn) also masqueraded as user scrolls to the split sync.
			guard !coordinator.scrollReportScheduled else { return }
			coordinator.scrollReportScheduled = true
			// RunLoop.perform rather than DispatchQueue.async: the observer
			// already runs on main, and the plain closure sidesteps Sendable
			// checking on the AppKit captures.
			RunLoop.main.perform { [weak scrollView, weak textView, weak coordinator] in
				guard let scrollView, let coordinator else { return }
				coordinator.scrollReportScheduled = false
				(scrollView.verticalRulerView as? LineNumberRulerView)?.invalidateLineNumbers()
				guard !coordinator.isSyncScroll else { return }
				let docHeight = scrollView.documentView?.frame.height ?? 0
				let visibleHeight = scrollView.contentView.bounds.height
				let offset = scrollView.contentView.bounds.origin.y
				// Only an actual origin change is a scroll — size/layout churn
				// at a stable position is not the user scrolling this pane.
				guard abs(offset - coordinator.lastReportedScrollOffset) > 0.5 else { return }
				coordinator.lastReportedScrollOffset = offset
				let fraction = docHeight > visibleHeight ? offset / (docHeight - visibleHeight) : 0
				if MarkdownSplitSyncLog.enabled {
					NSLog("[SplitSync] raw report offset=%.1f doc=%.1f frac=%.4f", offset, docHeight, fraction)
				}
				coordinator.parent.onScrollFractionChanged?(min(1, max(0, fraction)))

				guard let textView, coordinator.parent.onVisibleHeadingChanged != nil else { return }

				// Debounce the heading lookup + callback: any new scroll event
				// cancels the pending timer and re-arms it. The heading therefore
				// only updates once the user has stopped scrolling for a beat,
				// keeping the SwiftUI invalidation chain
				// (session.setCurrentSection → OutlineSidebar.body) entirely off
				// the active-scroll hot path.
				coordinator.headingDebounceTimer?.invalidate()
				coordinator.headingDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: false) { [weak coordinator, weak textView] _ in
					guard let coordinator, let textView else { return }
					coordinator.computeAndReportHeading(textView: textView)
				}
			}
		}

		return scrollView
	}

	public func updateNSView(_ scrollView: NSScrollView, context: Context) {
		context.coordinator.parent = self
		context.coordinator.isUpdatingFromSwiftUI = true
		defer { context.coordinator.isUpdatingFromSwiftUI = false }
		guard let textView = scrollView.documentView as? NSTextView else { return }

		// Setting `textView.font` writes the font attribute across the whole
		// textStorage, which clobbers the heading bolds the syntax highlighter
		// has already applied. SwiftUI re-enters updateNSView on every cursor
		// tick, so if we did this unconditionally the bolds would flash off on
		// each keystroke and only return when the highlight debounce caught
		// up — visible as headings "shimmering". Track the last-applied size
		// in the coordinator and only rewrite the font when it actually
		// changes.
		if context.coordinator.lastAppliedFontSize != fontSize {
			textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
			context.coordinator.lastAppliedFontSize = fontSize
		}
		applyTheme(to: textView, scrollView: scrollView, coordinator: context.coordinator)
		updateRuler(scrollView: scrollView, textView: textView)
		updateHighlightingIfNeeded(textView: textView, coordinator: context.coordinator)

		if textView.string != text {
			if MarkdownSplitSyncLog.enabled {
				NSLog("[SplitSync] raw string reassigned (viewLen=%d textLen=%d)", (textView.string as NSString).length, (text as NSString).length)
			}
			(scrollView.verticalRulerView as? LineNumberRulerView)?.noteTextChanged()
			let sel = textView.selectedRange()
			textView.string = text
			let clampedLoc = min(sel.location, (text as NSString).length)
			textView.setSelectedRange(NSRange(location: clampedLoc, length: 0))
			context.coordinator.scheduleIncrementalLayout(for: textView)
		}

		// Host-driven caret restore (undo/redo): once per token, place the
		// insertion point at the requested offset. Runs after any string
		// reassignment above so the offset lands in the restored text. Only the
		// focused editor restores its caret — in a split, the unfocused pane
		// setting a selection would show no caret and could fight the other pane.
		if let caret = caretTarget, caret.token != context.coordinator.lastCaretToken {
			context.coordinator.lastCaretToken = caret.token
			if textView.window?.firstResponder === textView {
				if MarkdownSplitSyncLog.enabled { NSLog("[SplitSync] raw caret scroll to %d", caret.offset) }
				let clamped = min(max(0, caret.offset), (textView.string as NSString).length)
				textView.setSelectedRange(NSRange(location: clamped, length: 0))
				textView.scrollRangeToVisible(NSRange(location: clamped, length: 0))
			}
		}

		applyMirroredSelection(to: textView, coordinator: context.coordinator)

		if let raw = selectedHeadingID, raw != context.coordinator.lastScrolledID {
			context.coordinator.lastScrolledID = raw
			let headingID = raw.components(separatedBy: "\t").first ?? raw
			if MarkdownSplitSyncLog.enabled { NSLog("[SplitSync] raw heading scroll %@", headingID) }
			if let range = MarkdownHeading.characterRange(for: headingID, in: text) {
				textView.scrollRangeToVisible(range)
				textView.showFindIndicator(for: range)
			}
			Task { @MainActor in selectedHeadingID = nil }
		}

		if let fraction = syncScrollFraction, fraction != context.coordinator.lastAppliedFraction {
			context.coordinator.lastAppliedFraction = fraction
			context.coordinator.isSyncScroll = true
			let docHeight = scrollView.documentView?.frame.height ?? 0
			let visibleHeight = scrollView.contentView.bounds.height
			let target = fraction * max(0, docHeight - visibleHeight)
			if MarkdownSplitSyncLog.enabled {
				NSLog("[SplitSync] raw driven frac=%.4f target=%.1f doc=%.1f", fraction, target, docHeight)
			}
			// Preserve x: with a line-number gutter the resting origin is
			// -contentInsets.left, and scrolling to x: 0 slid the text
			// horizontally underneath the ruler.
			scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: target))
			scrollView.reflectScrolledClipView(scrollView.contentView)
			// The driven offset counts as already reported, so notification
			// stragglers arriving after `isSyncScroll` clears (they can trail
			// by several runloop ticks) don't echo back as user scrolls.
			context.coordinator.lastReportedScrollOffset = target
			// Bounds-change observers queued on .main fire after this method
			// returns. Hold the flag until the next main-queue tick so the
			// echoed scroll is dropped instead of bouncing back as a fresh
			// "user scrolled" event.
			DispatchQueue.main.async { [weak coordinator = context.coordinator] in
				coordinator?.isSyncScroll = false
			}
		}

		if let offset = scrollToCharacterOffset, offset != context.coordinator.lastScrolledOffset {
			context.coordinator.lastScrolledOffset = offset
			context.coordinator.isSyncScroll = true
			let clampedOffset = min(offset, (textView.string as NSString).length)
			textView.scrollRangeToVisible(NSRange(location: clampedOffset, length: 0))
			context.coordinator.isSyncScroll = false
		}
	}

	public func makeCoordinator() -> Coordinator { Coordinator(self) }

	private func updateRuler(scrollView: NSScrollView, textView: NSTextView) {
		let hadRuler = scrollView.verticalRulerView != nil
		// Change indicators need the gutter even when line numbers are off —
		// the ruler then draws bars only.
		if showLineNumbers || lineChanges != nil {
			if scrollView.verticalRulerView == nil {
				let ruler = LineNumberRulerView(textView: textView)
				ruler.textColor = NSColor(theme?.secondaryColor ?? .secondary)
				scrollView.verticalRulerView = ruler
			}
			if let ruler = scrollView.verticalRulerView as? LineNumberRulerView {
				if ruler.showsNumbers != showLineNumbers { ruler.showsNumbers = showLineNumbers }
				if ruler.lineChanges != lineChanges { ruler.lineChanges = lineChanges }
			}
			if let ruler = scrollView.verticalRulerView as? LineNumberRulerView, let theme {
				let newColor = NSColor(theme.secondaryColor)
				if ruler.textColor != newColor {
					ruler.textColor = newColor
					ruler.needsDisplay = true
				}
				// Don't unconditionally call invalidateLineNumbers here —
				// the scrollObserver and textDidChange already invalidate
				// when state actually changes. Doing it on every
				// updateNSView added a redundant redraw per tick (the
				// session.currentSectionID flip from the scroll observer
				// fires this code path mid-scroll).
			}
			// Guard the setters: NSScrollView retiles on assignment even when
			// the value is unchanged, and this runs on every updateNSView.
			// The redundant tiles flapped the clip origin through its inset
			// states (0 / 7.5 / 8), spawned tracking-area churn (a storm of
			// synthetic mouseEntered/Exited events), and eroded the user's
			// scroll position toward the top while they were scrolling.
			if !scrollView.hasVerticalRuler { scrollView.hasVerticalRuler = true }
			if !scrollView.rulersVisible { scrollView.rulersVisible = true }
		} else if scrollView.verticalRulerView != nil {
			scrollView.hasVerticalRuler = false
			scrollView.rulersVisible = false
			scrollView.verticalRulerView = nil
		}
		// On first ruler attach (and on switch back), NSScrollView occasionally
		// fails to re-tile, leaving the text view's leading edge under the
		// ruler. Force a tile so the clip view's frame is recomputed before
		// the first draw.
		if hadRuler != (scrollView.verticalRulerView != nil) {
			scrollView.tile()
		}
	}

	private func updateHighlighting(textView: NSTextView) {
		if syntaxHighlightingEnabled, let theme {
			MarkdownSyntaxHighlighter.highlight(textView: textView, theme: theme, options: markdownOptions)
		} else if !syntaxHighlightingEnabled {
			MarkdownSyntaxHighlighter.clearHighlighting(textView: textView)
		}
	}

	/// Skip the textStorage rewrite when nothing that affects highlighting has
	/// actually changed. updateNSView gets called on every state tick (cursor
	/// reports, etc.) and the per-keystroke textStorage edit was making
	/// scrolling juddery because each call invalidated layout for the entire
	/// document.
	private func updateHighlightingIfNeeded(textView: NSTextView, coordinator: Coordinator) {
		if textView.string == coordinator.lastHighlightedText,
		   fontSize == coordinator.lastHighlightedFontSize,
		   syntaxHighlightingEnabled == coordinator.lastHighlightedSyntaxEnabled,
		   theme?.signature == coordinator.lastHighlightedThemeSignature,
		   markdownOptions == coordinator.lastHighlightedOptions {
			return
		}
		if MarkdownSplitSyncLog.enabled {
			NSLog("[SplitSync] raw re-highlight (textChanged=%d themeChanged=%d)",
				  textView.string != coordinator.lastHighlightedText ? 1 : 0,
				  theme?.signature != coordinator.lastHighlightedThemeSignature ? 1 : 0)
		}
		coordinator.lastHighlightedText = textView.string
		coordinator.lastHighlightedFontSize = fontSize
		coordinator.lastHighlightedSyntaxEnabled = syntaxHighlightingEnabled
		coordinator.lastHighlightedThemeSignature = theme?.signature
		coordinator.lastHighlightedOptions = markdownOptions
		updateHighlighting(textView: textView)
	}

	/// Show (or clear) the other pane's selection as an inactive-selection
	/// wash, via temporary attributes so nothing about the document changes.
	private func applyMirroredSelection(to textView: NSTextView, coordinator: Coordinator) {
		guard coordinator.lastMirroredSelection != mirroredSelection else { return }
		let textLength = (textView.string as NSString).length
		if let previous = coordinator.lastMirroredSelection,
		   previous.location + previous.length <= textLength {
			textView.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: previous)
		}
		coordinator.lastMirroredSelection = mirroredSelection
		if let range = mirroredSelection, range.length > 0, range.location + range.length <= textLength {
			// A mirror means the OTHER pane is active; this editor's leftover
			// (unemphasized) selection would read as a second selection.
			if textView.window?.firstResponder !== textView, textView.selectedRange().length > 0 {
				textView.setSelectedRange(NSRange(location: textView.selectedRange().location, length: 0))
			}
			textView.layoutManager?.addTemporaryAttribute(
				.backgroundColor,
				value: theme.map { NSColor($0.mirrorHighlightColor) } ?? .unemphasizedSelectedTextBackgroundColor,
				forCharacterRange: range)
		}
	}

	private func applyTheme(to textView: NSTextView, scrollView: NSScrollView, coordinator: Coordinator) {
		guard let theme else { return }
		// Only on actual theme changes: `NSTextView.textColor`'s setter
		// rewrites the attribute across the entire text storage even when the
		// color is unchanged, invalidating layout for the whole document.
		// Running that on every updateNSView (scroll state churn re-enters it
		// per scroll turn) forced TextKit to re-lay-out from the top to the
		// viewport each frame — large files crawled when scrolled deep.
		let signature = theme.signature
		guard signature != coordinator.lastAppliedThemeSignature else { return }
		coordinator.lastAppliedThemeSignature = signature
		let bg = NSColor(theme.backgroundColor)
		let fg = NSColor(theme.textColor)
		textView.backgroundColor = bg
		textView.textColor = fg
		textView.insertionPointColor = fg
		scrollView.drawsBackground = true
		scrollView.backgroundColor = bg
	}

	public class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
		var parent: MarkdownTextEditor
		var lastScrolledID: String?
		var scrollObserver: Any?
		var lastScrollTime: CFAbsoluteTime = 0
		var lastReportedHeading: String?
		var lastAppliedFraction: Double = -1
		var lastScrolledOffset: Int = -1
		var lastCaretToken: Int?
		var isSyncScroll = false
		/// Last bounds origin reported as a scroll. `boundsDidChange` also
		/// fires when TextKit's document-height estimate flaps during layout
		/// (constant offset, different fraction); reporting those as scrolls
		/// fed noise into the split-view sync and yanked the other pane around.
		var lastReportedScrollOffset: CGFloat = -1
		/// An end-of-turn scroll report is queued (see the bounds observer).
		var scrollReportScheduled = false
		/// In-flight incremental pre-layout of freshly set text.
		var prelayoutTask: Task<Void, Never>?

		/// Lay the document out ahead of scrolling. TextKit lays out lazily,
		/// so unvisited regions stall the scroll as they're reached — a
		/// fraction-of-second pause every screenful, worst deep in large
		/// files. A synchronous full pass fixes that but beachballs multi-
		/// hundred-KB documents at open, so big documents are laid out in
		/// chunks spread across runloop turns instead.
		func scheduleIncrementalLayout(for textView: NSTextView) {
			prelayoutTask?.cancel()
			guard let layoutManager = textView.layoutManager else { return }
			let length = (textView.string as NSString).length
			guard length > 100_000 else {
				layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: length))
				return
			}
			prelayoutTask = Task { @MainActor [weak textView] in
				var location = 0
				while location < length, !Task.isCancelled {
					guard let textView, let layoutManager = textView.layoutManager else { return }
					let end = min(location + 30_000, length)
					layoutManager.ensureLayout(forCharacterRange: NSRange(location: location, length: end - location))
					location = end
					try? await Task.sleep(for: .milliseconds(10))
				}
			}
		}
		var isUpdatingFromSwiftUI = false
		var lastAppliedFontSize: CGFloat = 0
		var lastHighlightedText: String?
		var lastHighlightedFontSize: CGFloat = 0
		var lastHighlightedSyntaxEnabled: Bool = false
		var lastHighlightedThemeSignature: String?
		var lastAppliedThemeSignature: String?
		var lastMirroredSelection: NSRange?
		var lastHighlightedOptions: MarkdownOptions?
		var headingDebounceTimer: Timer?
		var highlightDebounceTimer: Timer?
		/// Accumulates the edited range between debounced highlight passes.
		/// Cleared each time the debounced timer fires.
		var pendingHighlightRange: NSRange?
		init(_ parent: MarkdownTextEditor) { self.parent = parent }

		public func textStorage(
			_ textStorage: NSTextStorage,
			didProcessEditing editedMask: NSTextStorageEditActions,
			range editedRange: NSRange,
			changeInLength delta: Int
		) {
			// Only character edits affect highlighting scope. Attribute-only
			// edits (which we generate ourselves when applying styles) would
			// otherwise create a feedback loop.
			guard editedMask.contains(.editedCharacters) else { return }
			if let existing = pendingHighlightRange {
				pendingHighlightRange = NSUnionRange(existing, editedRange)
			} else {
				pendingHighlightRange = editedRange
			}
		}

		/// Runs once scrolling has been quiet for the debounce window. Reads
		/// the visible-top heading and reports it to the parent. Kept off the
		/// scroll observer's hot path so active scrolling doesn't fire
		/// SwiftUI invalidations through onVisibleHeadingChanged.
		fileprivate func computeAndReportHeading(textView: NSTextView) {
			guard let layoutManager = textView.layoutManager,
				  let textContainer = textView.textContainer else { return }
			let origin = textView.textContainerOrigin
			let point = NSPoint(x: 0, y: max(0, textView.visibleRect.minY - origin.y))
			let glyphIndex = layoutManager.glyphIndex(for: point, in: textContainer)
			guard glyphIndex < layoutManager.numberOfGlyphs else { return }
			let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
			let heading = MarkdownHeading.heading(atCharacterOffset: charIndex, in: textView.string)
			if heading?.id != lastReportedHeading {
				lastReportedHeading = heading?.id
				parent.onVisibleHeadingChanged?(heading?.id)
			}
		}
		deinit {
			if let obs = scrollObserver { NotificationCenter.default.removeObserver(obs) }
			headingDebounceTimer?.invalidate()
			highlightDebounceTimer?.invalidate()
		}

		public func textDidChange(_ notification: Notification) {
			guard let tv = notification.object as? NSTextView else { return }
			if let onSourceEdit = parent.onSourceEdit {
				onSourceEdit(tv.string, tv.selectedRange().location)
			} else {
				parent.text = tv.string
			}
			if parent.typewriterMode { centerCursor(in: tv) }
			(tv.enclosingScrollView?.verticalRulerView as? LineNumberRulerView)?.noteTextChanged()
			// Defer the re-highlight off the keystroke hot path: running 9
			// regexes + a font rewrite on every character was the dominant
			// source of typing lag. The cache is synced up front so that the
			// updateNSView triggered by `parent.text = tv.string` skips its
			// own highlight pass; the debounced timer below catches up after
			// the user stops typing for a beat.
			lastHighlightedText = tv.string
			lastHighlightedFontSize = parent.fontSize
			lastHighlightedSyntaxEnabled = parent.syntaxHighlightingEnabled
			lastHighlightedThemeSignature = parent.theme?.signature
			lastHighlightedOptions = parent.markdownOptions
			scheduleDebouncedHighlight(in: tv)
		}

		private func scheduleDebouncedHighlight(in textView: NSTextView) {
			guard parent.syntaxHighlightingEnabled, parent.theme != nil else { return }
			highlightDebounceTimer?.invalidate()
			highlightDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) { [weak self, weak textView] _ in
				guard let self, let textView, let theme = self.parent.theme else { return }
				let edited = self.pendingHighlightRange
				self.pendingHighlightRange = nil
				MarkdownSyntaxHighlighter.highlight(textView: textView, theme: theme, options: self.parent.markdownOptions, editedRange: edited)
			}
		}

		/// Focus arrived: report the current selection immediately so the
		/// split view clears this pane's stale mirror without waiting for a
		/// selection event — and remove the mirror wash synchronously, since
		/// the report's round trip back through SwiftUI state is visibly slow.
		/// `lastMirroredSelection` intentionally stays set: an interleaved
		/// update with the not-yet-cleared host state must not re-apply it.
		func reportSelectionOnFocus(_ textView: NSTextView) {
			if MarkdownSplitSyncLog.enabled {
				NSLog("[SplitSync] raw becomeFirstResponder mirror=%@ sel=%@", String(describing: lastMirroredSelection), NSStringFromRange(textView.selectedRange()))
			}
			if let stale = lastMirroredSelection,
			   stale.location + stale.length <= (textView.string as NSString).length {
				textView.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: stale)
			}
			guard parent.onSelectionChanged != nil else { return }
			let range = textView.selectedRange()
			parent.onSelectionChanged?(range.length > 0 ? range : nil)
		}

		public func textViewDidChangeSelection(_ notification: Notification) {
			guard !isUpdatingFromSwiftUI, let tv = notification.object as? NSTextView else { return }
			if parent.typewriterMode { centerCursor(in: tv) }
			reportCursorPosition(in: tv)
			if parent.onSelectionChanged != nil, tv.window?.firstResponder === tv {
				let range = tv.selectedRange()
				parent.onSelectionChanged?(range.length > 0 ? range : nil)
			}
		}

		private func reportCursorPosition(in textView: NSTextView) {
			guard parent.onCursorPositionChanged != nil else { return }
			let range = textView.selectedRange()
			let insertion = range.location
			let prefix = (textView.string as NSString).substring(to: min(insertion, (textView.string as NSString).length))
			let lines = prefix.components(separatedBy: "\n")
			parent.onCursorPositionChanged?(lines.count, (lines.last?.count ?? 0) + 1, range.length, insertion)
		}

		/// Typewriter scrolling with a dead band. Rather than hard-snapping the
		/// caret line to dead center on every keystroke — which reads as constant
		/// jitter — this leaves the scroll position alone while the caret sits
		/// within the comfortable middle band of the viewport, and only recenters
		/// once the caret has drifted past the band's top or bottom edge.
		private func centerCursor(in textView: NSTextView) {
			guard let scrollView = textView.enclosingScrollView,
					let layoutManager = textView.layoutManager else { return }
			let visibleHeight = scrollView.contentView.bounds.height
			guard visibleHeight > 0 else { return }
			let insertionPoint = textView.selectedRange().location
			let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: insertionPoint, length: 0), actualCharacterRange: nil)
			let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)

			let lineMidY = lineRect.midY + textView.textContainerOrigin.y
			let currentTop = scrollView.contentView.bounds.origin.y
			let caretInViewport = lineMidY - currentTop

			// Comfortable band: the middle ~40% of the viewport. While the caret
			// stays inside it, don't scroll at all.
			let center = visibleHeight / 2
			let bandHalf = visibleHeight * 0.2
			guard caretInViewport < center - bandHalf || caretInViewport > center + bandHalf else { return }

			// Drifted out of the band — recenter the caret line.
			let maxTop = max(0, (scrollView.documentView?.frame.height ?? 0) - visibleHeight)
			let targetTop = max(0, min(maxTop, lineMidY - center))
			guard abs(targetTop - currentTop) > 0.5 else { return }
			scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetTop))
			scrollView.reflectScrolledClipView(scrollView.contentView)
		}
	}
}

/// `NSScrollView` doesn't reserve horizontal space for our vertical line-number
/// ruler — it leaves the content view full-width at x=0, so the ruler draws over
/// the leading characters. This insets the content view by the ruler's thickness
/// after the standard tiling so the text always starts to the right of the gutter.
private final class RulerInsetScrollView: NSScrollView {
	override func tile() {
		// Standard NSScrollView tiling already places a vertical ruler beside
		// the content view — the frame surgery this subclass used to do (and
		// the contentInsets replacement tried next) both fought tile(),
		// producing either an endless retile loop that dragged the scroll
		// position, text sliding under the gutter, or wrap widths one gutter
		// too wide. Stock tiling handles the gutter; the only fix kept here
		// is restoring the reader's vertical position, which retiling is not
		// neutral about (its content-inset dance can reset the origin).
		let saved = contentView.bounds.origin.y
		super.tile()
		let clipHeight = contentView.bounds.height
		let docHeight = documentView?.frame.height ?? 0
		let y = min(max(0, saved), max(0, docHeight - clipHeight))
		if abs(contentView.bounds.origin.y - y) > 0.5 {
			contentView.scroll(to: NSPoint(x: contentView.bounds.origin.x, y: y))
			reflectScrolledClipView(contentView)
		}
	}
}
#endif
