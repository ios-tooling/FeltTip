//
//  MarkdownTextEditor.swift
//  MarkdownRendering
//

#if os(macOS)
import SwiftUI

/// Converts between AppKit clip-view origins and normalized scroll positions.
/// TextKit can temporarily position a large document at a negative Y origin,
/// so both directions must use the document frame's actual minimum rather
/// than assuming the scrollable range begins at zero.
enum MarkdownScrollGeometry {
	static func fraction(
		originY: CGFloat, documentFrame: CGRect, visibleHeight: CGFloat
	) -> Double {
		let minY = documentFrame.minY
		let maxY = max(minY, documentFrame.maxY - visibleHeight)
		let span = maxY - minY
		guard span > 0 else { return 0 }
		return Double(min(1, max(0, (originY - minY) / span)))
	}

	static func originY(
		fraction: Double, documentFrame: CGRect, visibleHeight: CGFloat
	) -> CGFloat {
		let minY = documentFrame.minY
		let maxY = max(minY, documentFrame.maxY - visibleHeight)
		let clamped = min(1, max(0, fraction))
		return minY + CGFloat(clamped) * (maxY - minY)
	}

	static func centeredOriginY(
		localMidY: CGFloat, documentFrame: CGRect, visibleHeight: CGFloat
	) -> CGFloat {
		let minY = documentFrame.minY
		let maxY = max(minY, documentFrame.maxY - visibleHeight)
		let midpointInScrollCoordinates = minY + localMidY
		return min(maxY, max(minY, midpointInScrollCoordinates - visibleHeight / 2))
	}
}
@preconcurrency import AppKit

public struct MarkdownTextEditor: NSViewRepresentable {
	@Binding var text: String
	@Binding var selectedHeadingID: String?
	/// SwiftUI skips `update{NS,UI}View` when a representable's stored
	/// properties compare equal to the last render, and a Binding compares by
	/// its snapshot value. That misses a host that changes the text and changes
	/// it back before SwiftUI renders in between (an edit the host immediately
	/// undoes, under load): the body re-evaluates, the value reads as unchanged,
	/// and the editor is left showing text the host no longer holds. A fresh
	/// token per body evaluation makes every host render reach the update,
	/// where the pending-local-text check decides whether the view must change.
	private let hostUpdateToken = UUID()
	@Environment(\.showLineNumbers) var showLineNumbers
	@Environment(\.syntaxHighlightingEnabled) var syntaxHighlightingEnabled
	@Environment(\.markdownOptions) var markdownOptions
	@Environment(\.markdownLineChanges) var lineChanges
	var fontSize: CGFloat = 13
	var onVisibleHeadingChanged: ((String?) -> Void)?
	var onScrollFractionChanged: ((Double) -> Void)?
	/// Token-gated viewport drive: host restores and split-pane sync both
	/// arrive here. A fresh token re-applies even an unchanged fraction.
	var scrollTarget: MarkdownScrollTarget?
	var typewriterMode: Bool = false
	var focusModeEnabled: Bool = false
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
	/// Reports the exact focused source range, including zero-length insertion
	/// points. Unlike `onSelectionChanged`, this is for editor handoff rather
	/// than cross-pane highlighting.
	var onSourceSelectionChanged: ((NSRange?) -> Void)?
	/// A selection made in the OTHER pane, shown here as an inactive-selection
	/// highlight (temporary layout attributes — the real selection, text
	/// storage, and undo state are untouched).
	var mirroredSelection: NSRange?
	var caretTarget: MarkdownCaretTarget?
	/// Token-gated source selection installed when this editor takes over from
	/// another mode. Applied even before first-responder handoff completes.
	var selectionTarget: MarkdownSelectionTarget?

	public init(
		text: Binding<String>,
		selectedHeadingID: Binding<String?>,
		fontSize: CGFloat = 13,
		onVisibleHeadingChanged: ((String?) -> Void)? = nil,
		onScrollFractionChanged: ((Double) -> Void)? = nil,
		scrollTarget: MarkdownScrollTarget? = nil,
		typewriterMode: Bool = false,
		focusModeEnabled: Bool = false,
		theme: MarkdownTheme? = nil,
		onCursorPositionChanged: ((Int, Int, Int, Int) -> Void)? = nil,
		onSourceEdit: ((String, Int) -> Void)? = nil,
		onSelectionChanged: ((NSRange?) -> Void)? = nil,
		onSourceSelectionChanged: ((NSRange?) -> Void)? = nil,
		mirroredSelection: NSRange? = nil,
		caretTarget: MarkdownCaretTarget? = nil,
		selectionTarget: MarkdownSelectionTarget? = nil
	) {
		self._text = text
		self._selectedHeadingID = selectedHeadingID
		self.fontSize = fontSize
		self.onVisibleHeadingChanged = onVisibleHeadingChanged
		self.onScrollFractionChanged = onScrollFractionChanged
		self.scrollTarget = scrollTarget
		self.typewriterMode = typewriterMode
		self.focusModeEnabled = focusModeEnabled
		self.theme = theme
		self.onCursorPositionChanged = onCursorPositionChanged
		self.onSourceEdit = onSourceEdit
		self.onSelectionChanged = onSelectionChanged
		self.onSourceSelectionChanged = onSourceSelectionChanged
		self.mirroredSelection = mirroredSelection
		self.caretTarget = caretTarget
		self.selectionTarget = selectionTarget
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
		// Markdown source is code-like text. System substitutions silently
		// corrupt authored syntax (for example, `---` table delimiters become
		// em dashes), so keep the raw pane source-faithful regardless of the
		// user's global typing preferences.
		textView.isAutomaticDashSubstitutionEnabled = false
		textView.isAutomaticQuoteSubstitutionEnabled = false
		textView.isAutomaticTextReplacementEnabled = false
		textView.isAutomaticSpellingCorrectionEnabled = false
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
		// NSTextView moves its selection to EOF when its initial string is assigned.
		// A pre-filled document should open at its beginning; on a large document,
		// leaving the caret at EOF also makes AppKit scroll the first frame to the end.
		textView.setSelectedRange(NSRange(location: 0, length: 0))
		let shouldRevealInitialCaret = selectionTarget == nil
			&& caretTarget == nil
			&& selectedHeadingID == nil
			&& scrollTarget == nil
		context.coordinator.lineIndex.rebuild(for: text)
		// Assigning the string can report a selection before the line index is
		// populated. Correct that initial report once SwiftUI has mounted the view.
		RunLoop.main.perform { [weak textView, weak coordinator = context.coordinator] in
			MainActor.assumeIsolated {
				guard let textView, let coordinator else { return }
				coordinator.reportCursorPosition(in: textView)
				// The initial string assignment can scroll a large NSTextView to EOF
				// before the representable is mounted. Reveal the initial caret after
				// layout unless the host supplied a more specific initial target.
				guard shouldRevealInitialCaret else { return }
				textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
			}
		}
		context.coordinator.scheduleIncrementalLayout(
			for: textView, revealStartWhenComplete: shouldRevealInitialCaret)
		// Wire the textStorage delegate so the coordinator can capture the
		// edited range — the incremental highlight path needs it to scope
		// re-styling to the paragraph that actually changed.
		textView.textStorage?.delegate = context.coordinator
		// TextKit's lazy layout, a rewrap after a width change, and a late
		// negative-origin shift all arrive as document frame changes. That is
		// the real "layout settled" signal the viewport anchor replays on.
		textView.postsFrameChangedNotifications = true
		context.coordinator.documentFrameObserver = NotificationCenter.default.addObserver(
			forName: NSView.frameDidChangeNotification,
			object: textView,
			queue: .main
		) { [weak scrollView, weak coordinator = context.coordinator] _ in
			MainActor.assumeIsolated {
				guard let scrollView, let coordinator else { return }
				coordinator.documentGeometryChanged(in: scrollView)
			}
		}

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
		updateRuler(
			scrollView: scrollView, textView: textView,
			coordinator: context.coordinator)
		context.coordinator.codeFenceRanges = MarkdownSyntaxHighlighter.fenceRanges(in: text)
		context.coordinator.scheduleHeadingIndex(for: text, debounce: false)
		updateHighlighting(textView: textView, coordinator: context.coordinator)
		context.coordinator.recordCurrentHighlightState()
		applyFocusMode(to: textView, coordinator: context.coordinator)

		context.coordinator.scrollObserver = NotificationCenter.default.addObserver(
			forName: NSView.boundsDidChangeNotification,
			object: scrollView.contentView,
			queue: .main
		) { [weak scrollView, weak textView, weak coordinator = context.coordinator] _ in
			MainActor.assumeIsolated {
				guard let scrollView, let coordinator, !coordinator.isSyncScroll else { return }
				if coordinator.viewportSizeChanged(
					to: scrollView.contentView.bounds.size, in: scrollView) {
					(scrollView.verticalRulerView as? LineNumberRulerView)?.invalidateLineNumbers()
					return
				}

				// Coalesce ALL reactions — including the ruler invalidation — to
				// the end of the runloop turn, and read the SETTLED offset.
				// Reacting synchronously to every bounds notification fed a
				// self-sustaining retile loop (invalidate → tile → bounds change →
				// invalidate …) that stormed at millisecond cadence and eroded the
				// user's scroll position; transient origins (e.g. 9 → 0 → 7.5 in
				// one turn) also masqueraded as user scrolls to the split sync.
				guard !coordinator.scrollReportScheduled else { return }
				coordinator.scrollReportScheduled = true
				RunLoop.main.perform { [weak scrollView, weak textView, weak coordinator] in
					MainActor.assumeIsolated {
						guard let scrollView, let coordinator else { return }
						coordinator.scrollReportScheduled = false
						(scrollView.verticalRulerView as? LineNumberRulerView)?.invalidateLineNumbers()
						guard !coordinator.isSyncScroll else { return }
						let documentFrame = scrollView.documentView?.frame ?? .zero
						let visibleHeight = scrollView.contentView.bounds.height
						let offset = scrollView.contentView.bounds.origin.y
						// Only an actual origin change is a scroll — size/layout churn
						// at a stable position is not the user scrolling this pane.
						guard abs(offset - coordinator.lastReportedScrollOffset) > 0.5 else { return }
						coordinator.lastReportedScrollOffset = offset
						// Right after a drive or a geometry change, TextKit can move
						// the clip origin on its own (clamping, a frame-origin shift).
						// Unless the user is actually scrolling, that is layout noise:
						// put the view back on its anchor instead of adopting it.
						if coordinator.takeScrollIsLayoutNoise() {
							coordinator.replayViewportAnchor(in: scrollView)
							return
						}
						// A genuine scroll is the user's choice of viewport: it becomes
						// the anchor and ends any restore in progress (including a
						// handoff selection that was being kept onscreen).
						coordinator.geometryWindowDeadline = 0
						let fraction = MarkdownScrollGeometry.fraction(
							originY: offset,
							documentFrame: documentFrame,
							visibleHeight: visibleHeight)
						coordinator.viewportAnchor = .fraction(fraction)
						if MarkdownSplitSyncLog.enabled {
							NSLog("[SplitSync] raw report offset=%.1f doc=%.1f frac=%.4f", offset, documentFrame.height, fraction)
						}
						coordinator.parent.onScrollFractionChanged?(fraction)

						guard let textView, coordinator.parent.onVisibleHeadingChanged != nil else { return }

						// Debounce the heading lookup + callback: any new scroll event
						// cancels the pending timer and re-arms it. The heading therefore
						// only updates once the user has stopped scrolling for a beat.
						coordinator.headingDebounceTimer?.invalidate()
						coordinator.headingDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: false) { [weak coordinator, weak textView] _ in
							MainActor.assumeIsolated {
								guard let coordinator, let textView else { return }
								coordinator.computeAndReportHeading(textView: textView)
							}
						}
					}
				}
			}
		}
		scrollView.postsFrameChangedNotifications = true
		context.coordinator.viewportObserver = NotificationCenter.default.addObserver(
			forName: NSView.frameDidChangeNotification,
			object: scrollView,
			queue: .main
		) { [weak scrollView, weak coordinator = context.coordinator] _ in
			MainActor.assumeIsolated {
				guard let scrollView, let coordinator else { return }
				coordinator.viewportSizeChanged(
					to: scrollView.contentView.bounds.size, in: scrollView)
			}
		}
		// Wheel, trackpad, and scroller drags are the one unambiguous "the user
		// is scrolling" signal AppKit offers; they always outrank a restore.
		context.coordinator.liveScrollObservers = [
			NotificationCenter.default.addObserver(
				forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: .main
			) { [weak coordinator = context.coordinator] _ in
				MainActor.assumeIsolated {
					coordinator?.isLiveScrolling = true
					coordinator?.liveScrolledThisTurn = true
				}
			},
			NotificationCenter.default.addObserver(
				forName: NSScrollView.didLiveScrollNotification, object: scrollView, queue: .main
			) { [weak coordinator = context.coordinator] _ in
				MainActor.assumeIsolated { coordinator?.liveScrolledThisTurn = true }
			},
			NotificationCenter.default.addObserver(
				forName: NSScrollView.didEndLiveScrollNotification, object: scrollView, queue: .main
			) { [weak coordinator = context.coordinator] _ in
				MainActor.assumeIsolated { coordinator?.isLiveScrolling = false }
			},
		]

		if let target = scrollTarget {
			// SwiftUI is not required to call updateNSView after this initial
			// construction. Apply the first host target once the scroll view has
			// joined a window and TextKit has had a turn to establish its height.
			RunLoop.main.perform { [weak scrollView, weak coordinator = context.coordinator] in
				MainActor.assumeIsolated {
					guard let scrollView, let coordinator,
						coordinator.parent.scrollTarget?.token == target.token else { return }
					coordinator.applyScrollTarget(target, to: scrollView)
				}
			}
		}
		RunLoop.main.perform { [weak scrollView, weak coordinator = context.coordinator] in
			MainActor.assumeIsolated {
				guard let scrollView, let coordinator else { return }
				let size = scrollView.contentView.bounds.size
				guard size.width > 0, size.height > 0 else { return }
				coordinator.lastViewportSize = size
			}
		}

		return scrollView
	}

	public func updateNSView(_ scrollView: NSScrollView, context: Context) {
		let previousHostText = context.coordinator.parent.text
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
		updateRuler(
			scrollView: scrollView, textView: textView,
			coordinator: context.coordinator)

		// Cursor/selection reports re-enter updateNSView continuously. Reading
		// `textView.string` bridges the complete NSTextStorage into a Swift
		// String, and the old equality check did that twice per tick (here and
		// in the highlight cache). Decide from host state plus the exact local
		// edit already reported by the delegate instead.
		if context.coordinator.shouldReplaceViewText(
			previousHostText: previousHostText, incomingText: text) {
			if MarkdownSplitSyncLog.enabled {
				NSLog("[SplitSync] raw string reassigned (textLen=%d)", (text as NSString).length)
			}
			(scrollView.verticalRulerView as? LineNumberRulerView)?.noteTextChanged()
			let sel = textView.selectedRange()
			let refreshIncrementalFind = scrollView.isFindBarVisible
			// A host replacement (typing in the other split pane, undo/redo)
			// reflows the document like local typing does; see `lastEditTime`.
			context.coordinator.lastEditTime = CFAbsoluteTimeGetCurrent()
			textView.string = text
			// NSTextView keeps an internal NSTextFinder for its native find bar.
			// Host-driven replacements (notably the app's custom undo/redo path)
			// bypass the edit notifications that make an incremental search rescan,
			// leaving its count and highlights stale even though `string` changed.
			// Ask the finder for the next match so it consumes the new client
			// string while preserving the query and replace interface. (This used
			// to synthesize a click on the bar's Next control; see
			// MarkdownFormattingTextView.performNextMatch for why that must not be
			// done.)
			if refreshIncrementalFind {
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak textView] in
					MainActor.assumeIsolated {
						// Only a bar in a live, visible window needs refreshing.
						guard let textView,
						      let window = textView.window, window.isVisible,
						      let scrollView = textView.enclosingScrollView,
						      scrollView.isFindBarVisible else { return }
						MarkdownFormattingTextView.performNextMatch(on: textView)
					}
				}
			}
			context.coordinator.lineIndex.rebuild(for: text)
			context.coordinator.lineNumberRuler?.setLineIndex(
				context.coordinator.lineIndex)
			context.coordinator.codeFenceRanges = MarkdownSyntaxHighlighter.fenceRanges(in: text)
			context.coordinator.scheduleHeadingIndex(for: text, debounce: false)
			let clampedLoc = min(sel.location, (text as NSString).length)
			textView.setSelectedRange(NSRange(location: clampedLoc, length: 0))
			RunLoop.main.perform { [weak textView, weak coordinator = context.coordinator] in
				MainActor.assumeIsolated {
					guard let textView, let coordinator else { return }
					coordinator.reportCursorPosition(in: textView)
				}
			}
			context.coordinator.scheduleIncrementalLayout(for: textView)
		}
		updateHighlightingIfNeeded(textView: textView, coordinator: context.coordinator)

		// Host-driven caret restore (undo/redo): once per token, place the
		// insertion point at the requested offset. Runs after any string
		// reassignment above so the offset lands in the restored text. Only the
		// focused editor restores its caret — in a split, the unfocused pane
		// setting a selection would show no caret and could fight the other pane.
		if let caret = caretTarget, caret.token != context.coordinator.lastCaretToken {
			if textView.window?.firstResponder === textView {
				// Consume only when the restore is actually applied. Menu
				// activation can temporarily move first responder; consuming
				// first permanently lost the caret request on the raw pane.
				context.coordinator.lastCaretToken = caret.token
				if MarkdownSplitSyncLog.enabled { NSLog("[SplitSync] raw caret scroll to %d", caret.offset) }
				let clamped = min(max(0, caret.offset), (textView.textStorage?.length ?? 0))
				let length = min(caret.selectionLength, (textView.textStorage?.length ?? 0) - clamped)
				let range = NSRange(location: clamped, length: length)
				textView.setSelectedRange(range)
				if !caret.preservesScrollPosition { textView.scrollRangeToVisible(range) }
			}
		}

		var appliedExtendedSelection = false
		if let target = selectionTarget,
		   target.token != context.coordinator.lastSelectionTargetToken {
			context.coordinator.lastSelectionTargetToken = target.token
			let length = (textView.textStorage?.length ?? 0)
			let location = min(max(0, target.range.location), length)
			let selectedLength = min(max(0, target.range.length), length - location)
			let range = NSRange(location: location, length: selectedLength)
			textView.setSelectedRange(range)
			if !target.preservesScrollPosition {
				context.coordinator.anchorViewport(
					toSelection: range, in: textView, scrollView: scrollView)
			}
			appliedExtendedSelection = range.length > 0
			// Selection notifications are intentionally ignored while SwiftUI is
			// driving this update, so publish the cursor position explicitly. Without
			// this, hosts keep the styled editor's stale line/column until the user
			// moves the caret in the raw editor.
			context.coordinator.reportCursorPosition(in: textView)
		}

		applyMirroredSelection(to: textView, coordinator: context.coordinator)
		applyFocusMode(to: textView, coordinator: context.coordinator)

		if let raw = selectedHeadingID, raw != context.coordinator.lastScrolledID {
			context.coordinator.lastScrolledID = raw
			let headingID = raw.components(separatedBy: "\t").first ?? raw
			if MarkdownSplitSyncLog.enabled { NSLog("[SplitSync] raw heading scroll %@", headingID) }
			// The heading index already knows every heading's range; rescan the
			// source only while a debounced edit has left it stale.
			let indexedRange = context.coordinator.indexedHeadingRevision == context.coordinator.contentRevision
				? context.coordinator.indexedHeadings.first { $0.id == headingID }?.sourceRange
				: nil
			if let range = indexedRange ?? MarkdownHeading.characterRange(for: headingID, in: text) {
				textView.scrollRangeToVisible(range)
				textView.showFindIndicator(for: range)
			}
			Task { @MainActor in selectedHeadingID = nil }
		}

		if let target = scrollTarget {
			if appliedExtendedSelection {
				// A selected source range is a stronger positional anchor than a
				// normalized viewport captured before the outgoing editor revealed
				// that selection. A target delivered alongside the handoff is that
				// stale viewport: consume it unapplied. Later tokens apply normally.
				context.coordinator.lastScrollTargetToken = target.token
			} else {
				context.coordinator.applyScrollTarget(target, to: scrollView)
			}
		}
	}


	public func makeCoordinator() -> Coordinator { Coordinator(self) }

	private func updateRuler(
		scrollView: NSScrollView,
		textView: NSTextView,
		coordinator: Coordinator
	) {
		let hadRuler = scrollView.verticalRulerView != nil
		// Change indicators need the gutter even when line numbers are off —
		// the ruler then draws bars only.
		if showLineNumbers || lineChanges != nil {
			if scrollView.verticalRulerView == nil {
				let ruler = LineNumberRulerView(textView: textView)
				ruler.textColor = NSColor(theme?.secondaryColor ?? .secondary)
				ruler.setLineIndex(coordinator.lineIndex)
				coordinator.lineNumberRuler = ruler
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
			coordinator.lineNumberRuler = nil
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

	private func updateHighlighting(textView: NSTextView, coordinator: Coordinator) {
		if syntaxHighlightingEnabled, let theme {
			let fences = coordinator.codeFenceRanges
				?? MarkdownSyntaxHighlighter.fenceRanges(in: textView.string)
			coordinator.codeFenceRanges = fences
			MarkdownSyntaxHighlighter.highlight(
				textView: textView, theme: theme, options: markdownOptions,
				codeFenceRanges: fences)
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
		if coordinator.contentRevision == coordinator.lastHighlightedContentRevision,
		   fontSize == coordinator.lastHighlightedFontSize,
		   syntaxHighlightingEnabled == coordinator.lastHighlightedSyntaxEnabled,
		   theme?.signature == coordinator.lastHighlightedThemeSignature,
		   markdownOptions == coordinator.lastHighlightedOptions {
			return
		}
		if MarkdownSplitSyncLog.enabled {
			NSLog("[SplitSync] raw re-highlight (textChanged=%d themeChanged=%d)",
				  coordinator.contentRevision != coordinator.lastHighlightedContentRevision ? 1 : 0,
				  theme?.signature != coordinator.lastHighlightedThemeSignature ? 1 : 0)
		}
		coordinator.recordCurrentHighlightState()
		updateHighlighting(textView: textView, coordinator: coordinator)
		coordinator.lastFocusRange = nil
	}

	/// Show (or clear) the other pane's selection as an inactive-selection
	/// wash, via temporary attributes so nothing about the document changes.
	private func applyMirroredSelection(to textView: NSTextView, coordinator: Coordinator) {
		guard coordinator.lastMirroredSelection != mirroredSelection else { return }
		let textLength = (textView.textStorage?.length ?? 0)
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

	private func applyFocusMode(to textView: NSTextView, coordinator: Coordinator) {
		let isActive = textView.window?.firstResponder === textView
		let shouldFocus = focusModeEnabled && isActive
		let nextRange = shouldFocus
			? MarkdownFocusMode.focusedRange(
				in: textView.textStorage?.mutableString ?? "", selection: textView.selectedRange())
			: nil
		guard coordinator.lastFocusRange != nextRange || coordinator.lastFocusModeEnabled != shouldFocus else { return }
		let full = NSRange(location: 0, length: (textView.textStorage?.length ?? 0))
		// Leaving focus mode must restore the syntax colors the dim replaced.
		// Moving between paragraphs while it stays on does not: the dim is
		// re-applied over the whole document below and hides them anyway, so
		// the ten-regex highlight pass per caret move was wasted work.
		if coordinator.lastFocusModeEnabled, !shouldFocus, full.length > 0 {
			updateHighlighting(textView: textView, coordinator: coordinator)
		}
		coordinator.lastFocusModeEnabled = shouldFocus
		coordinator.lastFocusRange = nextRange
		guard shouldFocus, let nextRange, full.length > 0 else { return }
		let active = NSColor(theme?.textColor ?? .primary)
		let background = theme.map { NSColor($0.backgroundColor) } ?? textView.backgroundColor
		// Keep the temporary drawing color opaque. TextKit can fail to draw
		// fallback-font glyphs (notably CJK) when their foreground temporary
		// attribute is translucent, making valid source appear to lose text.
		let dim = active.blended(withFraction: 0.7, of: background)?
			.withAlphaComponent(1) ?? active
		textView.layoutManager?.addTemporaryAttribute(.foregroundColor, value: dim, forCharacterRange: full)
		textView.layoutManager?.addTemporaryAttribute(.foregroundColor, value: active, forCharacterRange: nextRange)
	}

	private func clearFocusMode(from textView: NSTextView, coordinator: Coordinator) {
		guard coordinator.lastFocusModeEnabled else { return }
		updateHighlighting(textView: textView, coordinator: coordinator)
		coordinator.lastFocusModeEnabled = false
		coordinator.lastFocusRange = nil
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

	@MainActor
	public class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
		var parent: MarkdownTextEditor
		private var pendingReplacementSelection: NSRange?
		var lastScrolledID: String?
		var scrollObserver: Any?
		var viewportObserver: Any?
		var lastReportedHeading: String?
		var lastScrollTargetToken: Int?
		var lastCaretToken: Int?
		var lastSelectionTargetToken: Int?
		var isSyncScroll = false
		var lastViewportSize: CGSize = .zero
		/// Where this pane's viewport belongs. A user scroll, a host scroll
		/// target, and an extended selection handoff each replace it; every
		/// geometry change (late TextKit layout, a rewrap, a resize) re-applies
		/// whatever it currently is, so no replay can resurrect a superseded
		/// position and no timer has to guess when layout is done.
		var viewportAnchor: ViewportAnchor = .fraction(0)
		var documentFrameObserver: Any?
		var liveScrollObservers: [Any] = []
		var isLiveScrolling = false
		var liveScrolledThisTurn = false
		/// Until this instant, a non-live clip-origin change is layout noise
		/// following a drive or geometry change rather than a user scroll.
		var geometryWindowDeadline: CFAbsoluteTime = 0
		/// Frame changes caused by typing must not replay the anchor: the caret
		/// is leading the viewport, and re-driving by fraction would pull the
		/// text out from under it on every keystroke.
		var lastEditTime: CFAbsoluteTime = 0
		var geometryReplayScheduled = false
		static let geometryWindow: CFAbsoluteTime = 0.5
		static let editQuietPeriod: CFAbsoluteTime = 0.5
		/// A geometry replay deferred past the edit quiet period is waiting.
		var quietPeriodReplayPending = false

		enum ViewportAnchor: Equatable {
			case fraction(Double)
			case selection(NSRange)
		}

		/// Classifies the clip-origin change being reported this turn, consuming
		/// the per-turn live-scroll mark.
		func takeScrollIsLayoutNoise() -> Bool {
			let live = isLiveScrolling || liveScrolledThisTurn
			liveScrolledThisTurn = false
			return !live && CFAbsoluteTimeGetCurrent() < geometryWindowDeadline
		}

		private func openGeometryWindow() {
			geometryWindowDeadline = CFAbsoluteTimeGetCurrent() + Self.geometryWindow
		}
		/// Last bounds origin reported as a scroll. `boundsDidChange` also
		/// fires when TextKit's document-height estimate flaps during layout
		/// (constant offset, different fraction); reporting those as scrolls
		/// fed noise into the split-view sync and yanked the other pane around.
		var lastReportedScrollOffset: CGFloat = -1
		/// An end-of-turn scroll report is queued (see the bounds observer).
		var scrollReportScheduled = false
		/// In-flight incremental pre-layout of freshly set text.
		var prelayoutTask: Task<Void, Never>?
		/// Cancellable off-main heading-index build. Its matching content
		/// revision gates use of source ranges after rapid local or host edits.
		var headingIndexTask: Task<Void, Never>?
		var indexedHeadings: [MarkdownHeading] = []
		var indexedHeadingRevision = -1
		weak var lineNumberRuler: LineNumberRulerView?

		/// Lay the document out ahead of scrolling. TextKit lays out lazily,
		/// so unvisited regions stall the scroll as they're reached — a
		/// fraction-of-second pause every screenful, worst deep in large
		/// files. A synchronous full pass fixes that but beachballs multi-
		/// hundred-KB documents at open, so big documents are laid out in
		/// chunks spread across runloop turns instead.
		func scheduleIncrementalLayout(
			for textView: NSTextView,
			revealStartWhenComplete: Bool = false
		) {
			prelayoutTask?.cancel()
			guard let layoutManager = textView.layoutManager else { return }
			let length = (textView.textStorage?.length ?? 0)
			guard length > 100_000 else {
				layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: length))
				if revealStartWhenComplete {
					textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
				}
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
				guard !Task.isCancelled else { return }
				if revealStartWhenComplete, let textView {
					textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
				}
			}
		}

		/// Build a source-ordered heading index away from the AppKit thread.
		/// Local typing is debounced so a burst creates one parse; initial and
		/// external host loads start immediately. A superseded task cancels its
		/// parser, and the revision guard prevents stale ranges from publishing.
		@MainActor
		func scheduleHeadingIndex(for text: String, debounce: Bool) {
			headingIndexTask?.cancel()
			let revision = contentRevision
			headingIndexTask = Task { [weak self] in
				if debounce {
					do {
						try await Task.sleep(for: .milliseconds(200))
					} catch {
						return
					}
				}
				guard !Task.isCancelled else { return }
				let worker = Task.detached(priority: .utility) {
					MarkdownHeading.parse(from: text)
				}
				let headings = await withTaskCancellationHandler(
					operation: { await worker.value },
					onCancel: { worker.cancel() })
				guard !Task.isCancelled, let self,
				      self.contentRevision == revision else { return }
				self.indexedHeadings = headings
				self.indexedHeadingRevision = revision
			}
		}

		func visibleHeading(at offset: Int, in currentText: @autoclosure () -> String) -> MarkdownHeading? {
			if indexedHeadingRevision == contentRevision {
				return MarkdownHeading.heading(
					atCharacterOffset: offset, in: indexedHeadings)
			}
			// The index is briefly stale while a debounced edit refresh is
			// pending. Preserve exact behavior by scanning the live source
			// rather than consulting old ranges. The autoclosure keeps the
			// whole-document bridge off the common fresh-index path.
			return MarkdownHeading.heading(
				atCharacterOffset: offset, in: currentText())
		}
		var isUpdatingFromSwiftUI = false
		var lastAppliedFontSize: CGFloat = 0
		/// Monotonic text-storage generation. Highlight cache checks this
		/// integer instead of materializing/comparing the full raw document on
		/// every cursor-only SwiftUI update.
		private(set) var contentRevision = 0
		var lastHighlightedContentRevision = -1
		var lastHighlightedFontSize: CGFloat = 0
		var lastHighlightedSyntaxEnabled: Bool = false
		var lastHighlightedThemeSignature: String?
		var lastAppliedThemeSignature: String?
		var lastMirroredSelection: NSRange?
		var lastFocusRange: NSRange?
		var lastFocusModeEnabled = false
		var lastHighlightedOptions: MarkdownOptions?
		var headingDebounceTimer: Timer?
		var highlightDebounceTimer: Timer?
		/// Accumulates the edited range between debounced highlight passes.
		/// Cleared each time the debounced timer fires.
		var pendingHighlightRange: NSRange?
		/// Maintained incrementally so ordinary typing never runs the fence
		/// regex across the whole document.
		var codeFenceRanges: [NSRange]?
		/// UTF-16 offsets of logical line starts. Maintained incrementally from
		/// NSTextStorage edits so cursor reports can binary-search instead of
		/// allocating and splitting the entire prefix on every movement.
		var lineIndex = MarkdownLineIndex()
		/// Exact text most recently emitted by NSTextView but not yet observed
		/// coming back through the host binding.
		var pendingLocalText: String?
		init(_ parent: MarkdownTextEditor) { self.parent = parent }

		func applyScrollFraction(_ fraction: Double, to scrollView: NSScrollView) {
			isSyncScroll = true
			let documentFrame = scrollView.documentView?.frame ?? .zero
			let visibleHeight = scrollView.contentView.bounds.height
			let offset = MarkdownScrollGeometry.originY(
				fraction: fraction,
				documentFrame: documentFrame,
				visibleHeight: visibleHeight)
			if MarkdownSplitSyncLog.enabled {
				NSLog("[SplitSync] raw driven frac=%.4f target=%.1f doc=%.1f", fraction, offset, documentFrame.height)
			}
			// Preserve x: with a line-number gutter the resting origin is
			// -contentInsets.left, and scrolling to x: 0 slid the text
			// horizontally underneath the ruler.
			scrollView.contentView.scroll(to: NSPoint(
				x: scrollView.contentView.bounds.origin.x, y: offset))
			scrollView.reflectScrolledClipView(scrollView.contentView)
			lastReportedScrollOffset = offset
			// Bounds-change observers queued on .main fire after this method
			// returns. Hold the flag until the next main-queue tick so the
			// echoed scroll is dropped instead of bouncing back as a fresh
			// user scroll.
			DispatchQueue.main.async { [weak self] in self?.isSyncScroll = false }
		}

		/// Preserve the same normalized viewport when the containing layout
		/// changes width or height. TextKit keeps the old pixel offset while its
		/// document height changes, which otherwise makes opening a sidebar jump
		/// dozens of sections in a long raw document.
		@discardableResult
		func viewportSizeChanged(to size: CGSize, in scrollView: NSScrollView) -> Bool {
			guard size.width > 0, size.height > 0 else { return false }
			guard lastViewportSize != .zero else {
				lastViewportSize = size
				return true
			}
			guard abs(size.width - lastViewportSize.width) > 0.5
				|| abs(size.height - lastViewportSize.height) > 0.5 else { return false }
			if MarkdownSplitSyncLog.enabled {
				NSLog("[SplitSync] raw viewport %.1fx%.1f -> %.1fx%.1f anchor=%@",
					lastViewportSize.width, lastViewportSize.height, size.width, size.height,
					String(describing: viewportAnchor))
			}
			lastViewportSize = size
			documentGeometryChanged(in: scrollView)
			return true
		}

		/// The document frame or the viewport changed: the clip origin now
		/// describes a different place in the text, so re-apply the anchor.
		/// Coalesced to the end of the runloop turn — TextKit can post several
		/// frame changes while settling one layout pass.
		func documentGeometryChanged(in scrollView: NSScrollView) {
			guard !isLiveScrolling, !geometryReplayScheduled else { return }
			let sinceEdit = CFAbsoluteTimeGetCurrent() - lastEditTime
			if sinceEdit <= Self.editQuietPeriod {
				// A geometry change during the quiet period is usually the text
				// view laying out what was just typed, and replaying then would
				// fight the caret. But a host replacement also stamps lastEditTime,
				// and a large document can finish its layout inside the period;
				// dropping that change left the viewport at the top with its anchor
				// never applied. Look again once the period has passed.
				guard !quietPeriodReplayPending else { return }
				quietPeriodReplayPending = true
				let delay = Self.editQuietPeriod - sinceEdit + 0.02
				Task { @MainActor [weak self, weak scrollView] in
					try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
					guard let self else { return }
					self.quietPeriodReplayPending = false
					guard let scrollView else { return }
					self.documentGeometryChanged(in: scrollView)
				}
				return
			}
			geometryReplayScheduled = true
			RunLoop.main.perform { [weak self, weak scrollView] in
				MainActor.assumeIsolated {
					guard let self, let scrollView else { return }
					self.geometryReplayScheduled = false
					guard !self.isLiveScrolling else { return }
					if MarkdownSplitSyncLog.enabled {
						NSLog("[SplitSync] raw geometry doc=%.1f anchor=%@",
							scrollView.documentView?.frame.height ?? 0, String(describing: self.viewportAnchor))
					}
					self.openGeometryWindow()
					self.replayViewportAnchor(in: scrollView)
				}
			}
		}

		func applyScrollTarget(_ target: MarkdownScrollTarget, to scrollView: NSScrollView) {
			guard target.token != lastScrollTargetToken else { return }
			lastScrollTargetToken = target.token
			viewportAnchor = .fraction(Double(target.topFraction))
			openGeometryWindow()
			applyScrollFraction(Double(target.topFraction), to: scrollView)
		}

		/// Make a handed-off selection the viewport anchor and center it. A
		/// collapsed caret is revealed the same way but anchors by fraction, so a
		/// host scroll target applied afterwards owns the viewport.
		fileprivate func anchorViewport(
			toSelection range: NSRange, in textView: NSTextView, scrollView: NSScrollView
		) {
			openGeometryWindow()
			revealSelectionRange(range, in: textView, scrollView: scrollView)
			viewportAnchor = range.length > 0
				? .selection(range)
				: .fraction(currentFraction(in: scrollView))
		}

		/// Re-apply the current anchor to the current document geometry.
		func replayViewportAnchor(in scrollView: NSScrollView) {
			switch viewportAnchor {
			case .fraction(let fraction):
				applyScrollFraction(fraction, to: scrollView)
			case .selection(let range):
				guard let textView = scrollView.documentView as? NSTextView,
					textView.selectedRange() == range else {
					// The user moved on; keep the view where it is from now on.
					viewportAnchor = .fraction(currentFraction(in: scrollView))
					return
				}
				revealSelectionRange(range, in: textView, scrollView: scrollView)
			}
		}

		func currentFraction(in scrollView: NSScrollView) -> Double {
			MarkdownScrollGeometry.fraction(
				originY: scrollView.contentView.bounds.origin.y,
				documentFrame: scrollView.documentView?.frame ?? .zero,
				visibleHeight: scrollView.contentView.bounds.height)
		}

		fileprivate func revealSelectionRange(
			_ range: NSRange, in textView: NSTextView, scrollView: NSScrollView
		) {
			guard let layoutManager = textView.layoutManager,
				let textContainer = textView.textContainer,
				let documentView = scrollView.documentView else { return }
			layoutManager.ensureLayout(forCharacterRange: range)
			let glyphRange = layoutManager.glyphRange(
				forCharacterRange: range, actualCharacterRange: nil)
			let selectionRect = layoutManager.boundingRect(
				forGlyphRange: glyphRange, in: textContainer
			).offsetBy(
				dx: textView.textContainerOrigin.x,
				dy: textView.textContainerOrigin.y)
			let visibleHeight = scrollView.contentView.bounds.height
			let documentFrame = documentView.frame
			// TextKit can place a tall document at a negative frame origin. The
			// layout manager's rectangle is local to NSTextView, while the clip
			// view scrolls in the document frame's coordinate space; include that
			// origin before centering or the result clamps to the document bottom.
			let centeredY = MarkdownScrollGeometry.centeredOriginY(
				localMidY: selectionRect.midY,
				documentFrame: documentFrame,
				visibleHeight: visibleHeight)
			scrollView.contentView.scroll(to: NSPoint(
				x: scrollView.contentView.bounds.origin.x, y: centeredY))
			scrollView.reflectScrolledClipView(scrollView.contentView)
			// The bounds observer treats this programmatic move as an echo, not a
			// user scroll, so it cannot demote a selection anchor to a fraction.
			lastReportedScrollOffset = scrollView.contentView.bounds.origin.y
		}

		/// Whether updateNSView must replace NSTextView's storage. A matching
		/// pending local value is merely the normal binding round trip; a
		/// mismatch means the host rejected or superseded that local edit.
		func shouldReplaceViewText(
			previousHostText: String, incomingText: String
		) -> Bool {
			if let pendingLocalText {
				self.pendingLocalText = nil
				return pendingLocalText != incomingText
			}
			return previousHostText != incomingText
		}

		fileprivate func recordCurrentHighlightState() {
			lastHighlightedContentRevision = contentRevision
			lastHighlightedFontSize = parent.fontSize
			lastHighlightedSyntaxEnabled = parent.syntaxHighlightingEnabled
			lastHighlightedThemeSignature = parent.theme?.signature
			lastHighlightedOptions = parent.markdownOptions
		}

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
			contentRevision &+= 1
			// `string` copies the whole storage; `mutableString` is a live proxy.
			let storage = textStorage.mutableString
			lineIndex.applyEdit(in: storage, editedRange: editedRange, delta: delta)
			lineNumberRuler?.noteLineIndexChanged()
			codeFenceRanges = codeFenceRanges.flatMap {
				MarkdownFenceRangeTracker.updating($0, after: editedRange, delta: delta, in: storage)
			}
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
			let heading = visibleHeading(
				at: charIndex, in: textView.string)
			if heading?.id != lastReportedHeading {
				lastReportedHeading = heading?.id
				parent.onVisibleHeadingChanged?(heading?.id)
			}
		}
		isolated deinit {
			prelayoutTask?.cancel()
			headingIndexTask?.cancel()
			if let obs = scrollObserver { NotificationCenter.default.removeObserver(obs) }
			if let obs = viewportObserver { NotificationCenter.default.removeObserver(obs) }
			if let obs = documentFrameObserver { NotificationCenter.default.removeObserver(obs) }
			liveScrollObservers.forEach { NotificationCenter.default.removeObserver($0) }
			headingDebounceTimer?.invalidate()
			highlightDebounceTimer?.invalidate()
		}

		public func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
			let selected = textView.selectedRange()
			pendingReplacementSelection = selected.length > 0 && selected == affectedCharRange ? selected : nil
			return true
		}

		public func textDidChange(_ notification: Notification) {
			guard let tv = notification.object as? NSTextView else { return }
			let updatedText = tv.string
			pendingLocalText = updatedText
			lastEditTime = CFAbsoluteTimeGetCurrent()
			scheduleHeadingIndex(for: updatedText, debounce: true)
			if let selected = pendingReplacementSelection {
				// Re-publish immediately before the edit: AppKit may already have
				// reported the collapsed post-edit caret to the host.
				parent.onSourceSelectionChanged?(selected)
			}
			pendingReplacementSelection = nil
			if let onSourceEdit = parent.onSourceEdit {
				onSourceEdit(updatedText, tv.selectedRange().location)
			} else {
				parent.text = updatedText
			}
			if parent.typewriterMode { centerCursor(in: tv) }
			(tv.enclosingScrollView?.verticalRulerView as? LineNumberRulerView)?
				.invalidateLineNumbers()
			// Defer the re-highlight off the keystroke hot path: running 9
			// regexes + a font rewrite on every character was the dominant
			// source of typing lag. The cache is synced up front so that the
			// updateNSView triggered by `parent.text = tv.string` skips its
			// own highlight pass; the debounced timer below catches up after
			// the user stops typing for a beat.
			recordCurrentHighlightState()
			scheduleDebouncedHighlight(in: tv)
		}

		private func scheduleDebouncedHighlight(in textView: NSTextView) {
			guard parent.syntaxHighlightingEnabled, parent.theme != nil else { return }
			highlightDebounceTimer?.invalidate()
			highlightDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) { [weak self, weak textView] _ in
				MainActor.assumeIsolated {
					guard let self, let textView, let theme = self.parent.theme else { return }
					let edited = self.pendingHighlightRange
					self.pendingHighlightRange = nil
					let fences = self.codeFenceRanges
						?? MarkdownSyntaxHighlighter.fenceRanges(in: textView.string)
					self.codeFenceRanges = fences
					MarkdownSyntaxHighlighter.highlight(
						textView: textView, theme: theme,
						options: self.parent.markdownOptions, editedRange: edited,
						codeFenceRanges: fences)
				}
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
			   stale.location + stale.length <= (textView.textStorage?.length ?? 0) {
				textView.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: stale)
			}
			let range = textView.selectedRange()
			parent.applyFocusMode(to: textView, coordinator: self)
			parent.onSourceSelectionChanged?(range)
			parent.onSelectionChanged?(range.length > 0 ? range : nil)
		}

		func reportFocusLoss(_ textView: NSTextView) {
			parent.clearFocusMode(from: textView, coordinator: self)
		}

		public func textViewDidChangeSelection(_ notification: Notification) {
			guard !isUpdatingFromSwiftUI, let tv = notification.object as? NSTextView else { return }
			if parent.typewriterMode { centerCursor(in: tv) }
			parent.applyFocusMode(to: tv, coordinator: self)
			reportCursorPosition(in: tv)
			// The native Find bar gives keyboard focus to its field editor while it
			// moves the text view's real selection. Report those ranges as active
			// selections too, or a host can retain and later reapply a stale mode-
			// handoff target when Done returns focus to the editor.
			if tv.window?.firstResponder === tv
				|| tv.enclosingScrollView?.isFindBarVisible == true {
				let range = tv.selectedRange()
				parent.onSourceSelectionChanged?(range)
				parent.onSelectionChanged?(range.length > 0 ? range : nil)
			}
		}

		public func textDidBeginEditing(_ notification: Notification) {
			guard let textView = notification.object as? NSTextView else { return }
			parent.applyFocusMode(to: textView, coordinator: self)
		}

		public func textDidEndEditing(_ notification: Notification) {
			guard let textView = notification.object as? NSTextView else { return }
			parent.clearFocusMode(from: textView, coordinator: self)
		}

		func reportCursorPosition(in textView: NSTextView) {
			guard parent.onCursorPositionChanged != nil else { return }
			let range = textView.selectedRange()
			let insertion = range.location
			let position = lineIndex.position(at: insertion)
			parent.onCursorPositionChanged?(
				position.line, position.column, range.length, insertion)
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
	override var isFindBarVisible: Bool {
		didSet {
			guard oldValue, !isFindBarVisible,
			      let textView = documentView as? NSTextView else { return }
			let foundRange = textView.selectedRange()
			// AppKit may leave the window itself (or an unrelated sibling) as
			// first responder after Escape closes the native find bar. Restore
			// the document view on the next turn so the found range remains the
			// active editing selection for an immediate formatting shortcut.
			RunLoop.main.perform { [weak self, weak textView] in
				MainActor.assumeIsolated {
					guard let self, let textView, !self.isFindBarVisible else { return }
					if foundRange.length > 0,
					   foundRange.upperBound <= (textView.textStorage?.length ?? 0) {
						textView.setSelectedRange(foundRange)
					}
					self.window?.makeFirstResponder(textView)
				}
			}
		}
	}

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
		let documentFrame = documentView?.frame ?? .zero
		let minY = documentFrame.minY
		let maxY = max(minY, documentFrame.maxY - clipHeight)
		let y = min(max(minY, saved), maxY)
		if abs(contentView.bounds.origin.y - y) > 0.5 {
			contentView.scroll(to: NSPoint(x: contentView.bounds.origin.x, y: y))
			reflectScrolledClipView(contentView)
		}
	}
}
#endif
