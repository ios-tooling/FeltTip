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
	var fontSize: CGFloat = 13
	var onVisibleHeadingChanged: ((String?) -> Void)?
	var onScrollFractionChanged: ((Double) -> Void)?
	var syncScrollFraction: Double?
	var typewriterMode: Bool = false
	var theme: MarkdownTheme?
	var onCursorPositionChanged: ((Int, Int, Int, Int) -> Void)?
	var scrollToCharacterOffset: Int?

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
		scrollToCharacterOffset: Int? = nil
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
		self.scrollToCharacterOffset = scrollToCharacterOffset
	}

	public func makeNSView(context: Context) -> NSScrollView {
		let scrollView = NSScrollView()
		let textView = MarkdownFormattingTextView()

		textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
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
		// Wire the textStorage delegate so the coordinator can capture the
		// edited range — the incremental highlight path needs it to scope
		// re-styling to the paragraph that actually changed.
		textView.textStorage?.delegate = context.coordinator

		scrollView.documentView = textView
		scrollView.hasVerticalScroller = true
		scrollView.autohidesScrollers = true
		scrollView.contentView.postsBoundsChangedNotifications = true
		applyTheme(to: textView, scrollView: scrollView)
		updateRuler(scrollView: scrollView, textView: textView)
		updateHighlighting(textView: textView)

		context.coordinator.scrollObserver = NotificationCenter.default.addObserver(
			forName: NSView.boundsDidChangeNotification,
			object: scrollView.contentView,
			queue: .main
		) { [weak scrollView, weak textView, weak coordinator = context.coordinator] _ in
			guard let scrollView, let coordinator, !coordinator.isSyncScroll else { return }

			let docHeight = scrollView.documentView?.frame.height ?? 0
			let visibleHeight = scrollView.contentView.bounds.height
			let offset = scrollView.contentView.bounds.origin.y
			let fraction = docHeight > visibleHeight ? offset / (docHeight - visibleHeight) : 0
			coordinator.parent.onScrollFractionChanged?(min(1, max(0, fraction)))
			(scrollView.verticalRulerView as? LineNumberRulerView)?.invalidateLineNumbers()

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

		return scrollView
	}

	public func updateNSView(_ scrollView: NSScrollView, context: Context) {
		context.coordinator.parent = self
		context.coordinator.isUpdatingFromSwiftUI = true
		defer { context.coordinator.isUpdatingFromSwiftUI = false }
		guard let textView = scrollView.documentView as? NSTextView else { return }

		let expectedFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
		if textView.font != expectedFont { textView.font = expectedFont }
		applyTheme(to: textView, scrollView: scrollView)
		updateRuler(scrollView: scrollView, textView: textView)
		updateHighlightingIfNeeded(textView: textView, coordinator: context.coordinator)

		if textView.string != text {
			let sel = textView.selectedRange()
			textView.string = text
			let clampedLoc = min(sel.location, (text as NSString).length)
			textView.setSelectedRange(NSRange(location: clampedLoc, length: 0))
			// Force a full-document layout pass after loading new text so
			// TextKit doesn't dribble out per-chunk relayouts as the user
			// scrolls into previously unseen regions — the visible symptom
			// was a fraction-of-second pause every screenful, even with
			// syntax highlighting and line numbers disabled.
			if let lm = textView.layoutManager {
				lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: (text as NSString).length))
			}
		}

		if let raw = selectedHeadingID, raw != context.coordinator.lastScrolledID {
			context.coordinator.lastScrolledID = raw
			let headingID = raw.components(separatedBy: "\t").first ?? raw
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
			scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
			scrollView.reflectScrolledClipView(scrollView.contentView)
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
		if showLineNumbers {
			if scrollView.verticalRulerView == nil {
				let ruler = LineNumberRulerView(textView: textView)
				ruler.textColor = NSColor(theme?.secondaryColor ?? .secondary)
				scrollView.verticalRulerView = ruler
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
			scrollView.hasVerticalRuler = true
			scrollView.rulersVisible = true
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
		   theme == coordinator.lastHighlightedTheme,
		   markdownOptions == coordinator.lastHighlightedOptions {
			return
		}
		coordinator.lastHighlightedText = textView.string
		coordinator.lastHighlightedFontSize = fontSize
		coordinator.lastHighlightedSyntaxEnabled = syntaxHighlightingEnabled
		coordinator.lastHighlightedTheme = theme
		coordinator.lastHighlightedOptions = markdownOptions
		updateHighlighting(textView: textView)
	}

	private func applyTheme(to textView: NSTextView, scrollView: NSScrollView) {
		guard let theme else { return }
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
		var isSyncScroll = false
		var isUpdatingFromSwiftUI = false
		var lastHighlightedText: String?
		var lastHighlightedFontSize: CGFloat = 0
		var lastHighlightedSyntaxEnabled: Bool = false
		var lastHighlightedTheme: MarkdownTheme?
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
			parent.text = tv.string
			if parent.typewriterMode { centerCursor(in: tv) }
			(tv.enclosingScrollView?.verticalRulerView as? LineNumberRulerView)?.invalidateLineNumbers()
			// Defer the re-highlight off the keystroke hot path: running 9
			// regexes + a font rewrite on every character was the dominant
			// source of typing lag. The cache is synced up front so that the
			// updateNSView triggered by `parent.text = tv.string` skips its
			// own highlight pass; the debounced timer below catches up after
			// the user stops typing for a beat.
			lastHighlightedText = tv.string
			lastHighlightedFontSize = parent.fontSize
			lastHighlightedSyntaxEnabled = parent.syntaxHighlightingEnabled
			lastHighlightedTheme = parent.theme
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

		public func textViewDidChangeSelection(_ notification: Notification) {
			guard !isUpdatingFromSwiftUI, let tv = notification.object as? NSTextView else { return }
			if parent.typewriterMode { centerCursor(in: tv) }
			reportCursorPosition(in: tv)
		}

		private func reportCursorPosition(in textView: NSTextView) {
			guard parent.onCursorPositionChanged != nil else { return }
			let range = textView.selectedRange()
			let insertion = range.location
			let prefix = (textView.string as NSString).substring(to: min(insertion, (textView.string as NSString).length))
			let lines = prefix.components(separatedBy: "\n")
			parent.onCursorPositionChanged?(lines.count, (lines.last?.count ?? 0) + 1, range.length, insertion)
		}

		private func centerCursor(in textView: NSTextView) {
			guard let scrollView = textView.enclosingScrollView,
					let layoutManager = textView.layoutManager else { return }
			let insertionPoint = textView.selectedRange().location
			let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: insertionPoint, length: 0), actualCharacterRange: nil)
			let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
			let visibleHeight = scrollView.contentView.bounds.height
			let targetY = lineRect.midY + textView.textContainerOrigin.y - visibleHeight / 2
			scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, targetY)))
			scrollView.reflectScrolledClipView(scrollView.contentView)
		}
	}
}
#endif
