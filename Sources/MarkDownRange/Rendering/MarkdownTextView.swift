//
//  MarkdownTextView.swift
//  MarkDownRange
//
//  Phase 2 of the single-NSTextView renderer. Wraps NSScrollView + NSTextView,
//  drives them with the NSAttributedString produced by MarkdownAttributedStringBuilder.
//  No section/scroll-fraction tracking yet — that's phase 3.
//

#if os(macOS)
import AppKit
import SwiftUI

public struct MarkdownTextView: NSViewRepresentable {
	let text: String
	let theme: MarkdownTheme
	let fontSize: CGFloat
	var baseURL: URL?
	var header: AnyView?
	private let headerToken: AnyHashable?
	/// Optional TOC selection binding. When the wrapped value changes the
	/// renderer scrolls to the matching heading. We never write back — clearing
	/// the value is the caller's responsibility (the tap-counter pattern in
	/// `OutlineSidebar` keeps repeated taps on the same heading distinguishable
	/// without needing a reset).
	var selectedHeadingID: Binding<String?>?
	/// Maximum width of the rendered text column. The scroll view still fills
	/// the parent (so its scroller stays at the window edge); the inset of
	/// the underlying NSTextView is adjusted to center the text within this
	/// width. `nil` means no constraint (text fills the available width).
	public var contentMaxWidth: CGFloat?
	/// Minimum horizontal inset to keep around the text column even when the
	/// content has no width constraint. Default 24.
	public var minimumHorizontalInset: CGFloat = 24
	/// Reports the formatted-view rebuild's lifecycle. Passes `0` when a
	/// render task starts, fractional values 0…1 as attachment-bearing
	/// blocks are measured, and `nil` once the rendered text has been
	/// committed to the text view. The hosting screen uses this to drive a
	/// determinate progress bar in the loading overlay.
	public var onRenderProgress: (@MainActor @Sendable (Double?) -> Void)?
	/// Reports the scroll viewport as fractions of the document's rendered
	/// height — `topFraction` is the y-offset of the top of the visible area
	/// (0 at the top, 1 at the bottom), `visibleFraction` is what proportion
	/// of the document is currently on screen. Used by external scrubbers /
	/// minimaps to show "where am I" without owning the scroll view.
	public var onScrollFractionChanged: (@MainActor @Sendable (_ topFraction: CGFloat, _ visibleFraction: CGFloat) -> Void)?
	/// Imperative scroll request. Set a new target (with a unique `token`) and
	/// the renderer scrolls so `topFraction` of the document's rendered height
	/// is centered in the visible area. Used by external scrubbers; the token
	/// is what lets repeated requests for the same fraction (e.g. continuous
	/// drag updates) re-fire instead of being deduped by SwiftUI equality.
	public var scrollTarget: MarkdownScrollTarget?
	/// Relative scroll request: nudges the current scroll position by
	/// `deltaY` pixels. Used by an external scroll-wheel handler (the
	/// minimap forwards wheel events here) so the doc scrolls without
	/// having to know its own height. Token-gated like `scrollTarget`.
	public var scrollDelta: MarkdownScrollDelta?
	/// Per-phase timings for each render pass — benchmarking hook. See
	/// `MarkdownRenderPhases`.
	public var onRenderPhases: (@MainActor @Sendable (MarkdownRenderPhases) -> Void)?
	@Environment(LinkDisplayState.self) private var linkDisplay

	public init(text: String, theme: MarkdownTheme, fontSize: CGFloat, baseURL: URL? = nil, contentMaxWidth: CGFloat? = nil) {
		self.text = text
		self.theme = theme
		self.fontSize = fontSize
		self.baseURL = baseURL
		self.contentMaxWidth = contentMaxWidth
		self.header = nil
		self.headerToken = nil
	}

	/// Prepends an arbitrary SwiftUI view as a scrollable header inside the
	/// same NSTextView. `headerToken` participates in the render key so the
	/// header is rebuilt only when its identity changes — pass an Equatable/
	/// Hashable token that captures everything the header depends on (e.g. an
	/// item id).
	public init<HeaderToken: Hashable>(text: String, theme: MarkdownTheme, fontSize: CGFloat, baseURL: URL? = nil, headerToken: HeaderToken, @ViewBuilder header: () -> some View) {
		self.text = text
		self.theme = theme
		self.fontSize = fontSize
		self.baseURL = baseURL
		self.header = AnyView(header())
		self.headerToken = AnyHashable(headerToken)
	}

	/// Wire a TOC selection binding. Tapping a heading in an external outline
	/// sets the binding to a unique value (typically `"<id>\t<tapCounter>"`);
	/// the renderer detects the change and scrolls to that heading.
	public func selectedHeading(_ binding: Binding<String?>) -> Self {
		var copy = self
		copy.selectedHeadingID = binding
		return copy
	}

	/// Subscribe to formatted-view rebuild progress. The closure receives `0`
	/// when a render task starts, fractional values during the build phase,
	/// and `nil` once the rendered text is committed. Used by the document
	/// screen to drive a determinate progress bar in the loading overlay.
	public func onRenderProgress(_ callback: @escaping @MainActor @Sendable (Double?) -> Void) -> Self {
		var copy = self
		copy.onRenderProgress = callback
		return copy
	}

	/// Subscribe to scroll-viewport changes (see `onScrollFractionChanged`).
	/// Fires on every clip-view bounds change, plus once at attach time so
	/// hosts can show the right viewport rectangle without waiting for a
	/// scroll event.
	public func onScrollFractionChanged(_ callback: @escaping @MainActor @Sendable (CGFloat, CGFloat) -> Void) -> Self {
		var copy = self
		copy.onScrollFractionChanged = callback
		return copy
	}

	/// Drive the renderer's scroll position from outside (minimap drag-scrub,
	/// for instance). Bumping the target's `token` is what triggers the scroll;
	/// the renderer ignores updates whose token it has already handled, so
	/// state-driven callers can leave the binding set without re-firing.
	public func scrollTarget(_ target: MarkdownScrollTarget?) -> Self {
		var copy = self
		copy.scrollTarget = target
		return copy
	}

	/// Apply a relative scroll delta from outside the renderer (e.g. the
	/// minimap forwarding scroll-wheel events). Token-gated so a state-
	/// driven binding that survives unrelated body re-renders doesn't
	/// re-scroll.
	public func scrollDelta(_ delta: MarkdownScrollDelta?) -> Self {
		var copy = self
		copy.scrollDelta = delta
		return copy
	}

	/// Subscribe to per-phase render timings. Fires once per render pass
	/// (parse + build + commit + initial layout). Benchmarking only.
	public func onRenderPhases(_ callback: @escaping @MainActor @Sendable (MarkdownRenderPhases) -> Void) -> Self {
		var copy = self
		copy.onRenderPhases = callback
		return copy
	}

	public func makeNSView(context: Context) -> NSScrollView {
		let scrollView = NSScrollView()
		scrollView.hasVerticalScroller = true
		scrollView.hasHorizontalScroller = false
		scrollView.autohidesScrollers = true
		scrollView.borderType = .noBorder
		scrollView.drawsBackground = true

		let textView = MarkdownTextViewBacking(frame: .zero)
		textView.isEditable = false
		textView.isSelectable = true
		textView.allowsUndo = false
		textView.drawsBackground = false
		textView.usesFindBar = true
		textView.isIncrementalSearchingEnabled = true
		// The actual horizontal inset is set by Coordinator.applyHorizontalInset
		// based on contentMaxWidth; this initial value just avoids a zero-inset
		// flash before the first updateNSView pass.
		textView.textContainerInset = NSSize(width: minimumHorizontalInset, height: 0)
		textView.delegate = context.coordinator
		textView.isVerticallyResizable = true
		textView.isHorizontallyResizable = false
		textView.autoresizingMask = [.width]
		textView.minSize = NSSize(width: 0, height: 0)
		textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
		textView.textContainer?.widthTracksTextView = true
		textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

		scrollView.documentView = textView
		context.coordinator.textView = textView
		textView.onLinkHover = { [linkDisplay] url in
			if linkDisplay.displayedURL != url { linkDisplay.displayedURL = url }
		}
		// AppKit fires this after the text view has been laid out inside the
		// scroll view's clip view — the only reliably-non-zero moment we
		// have to mount any attachments TextKit skipped because the earlier
		// dispatch ran while bounds were still zero.
		textView.onDidLayout = { [weak coordinator = context.coordinator, weak textView] in
			guard let textView, let coordinator, textView.window != nil else { return }
			coordinator.didLayoutTextView(textView)
		}
		return scrollView
	}

	public func updateNSView(_ scrollView: NSScrollView, context: Context) {
		guard let textView = scrollView.documentView as? NSTextView else { return }
		context.coordinator.parent = self
		// Reassigning a layer-backed view's backgroundColor — even to the
		// same value — marks it for redisplay. On a no-op reload that flush
		// briefly blanks every visible attachment's hosting view (a one-frame
		// image flash), so only assign when the value actually changed.
		let bgColor = NSColor(theme.backgroundColor)
		if scrollView.backgroundColor != bgColor { scrollView.backgroundColor = bgColor }
		if textView.backgroundColor != bgColor { textView.backgroundColor = bgColor }
		if let backing = textView as? MarkdownTextViewBacking {
			let barColor = NSColor(theme.linkColor)
			if backing.blockquoteBarColor != barColor { backing.blockquoteBarColor = barColor }
		}
		context.coordinator.attachFrameObserver(to: textView)
		context.coordinator.attachScrollObserver(to: scrollView)
		context.coordinator.applyHorizontalInset(to: textView)
		context.coordinator.render(into: textView)
		context.coordinator.handleSelectedHeading(in: textView)
		context.coordinator.handleScrollTarget(in: textView)
		context.coordinator.handleScrollDelta(in: textView)
	}

	public func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

	@MainActor
	public final class Coordinator: NSObject, NSTextViewDelegate {
		var parent: MarkdownTextView
		weak var textView: NSTextView?
		var lastRenderKey: RenderKey?
		private var cacheToken: UUID?
		private var rebuildTask: Task<Void, Never>?
		private var renderTask: Task<Void, Never>?
		private var lastObservedWidth: CGFloat = 0
		private var frameObserver: NSObjectProtocol?
		/// The most recent TOC selection we've acted on. Tracking it lets us
		/// distinguish "binding changed because the user tapped a heading"
		/// (scroll) from "binding is still the same value across an unrelated
		/// updateNSView pass" (skip).
		private var lastSelectedHeading: String?
		private var flashTask: Task<Void, Never>?
		private var remountTask: Task<Void, Never>?
		private var scrollObserver: NSObjectProtocol?
		private var lastScrollTargetToken: Int?
		private var lastScrollDeltaToken: Int?

		init(parent: MarkdownTextView) {
			self.parent = parent
			super.init()
			cacheToken = ImageDimensionCache.shared.subscribe { [weak self] in
				Task { @MainActor [weak self] in self?.scheduleRebuild() }
			}
		}

		deinit {
			renderTask?.cancel()
			remountTask?.cancel()
			if let cacheToken { ImageDimensionCache.shared.unsubscribe(cacheToken) }
			// frameObserver block uses [weak self]; once we're gone, its
			// callback no-ops. Skipping removeObserver here avoids a
			// non-Sendable access in this nonisolated deinit.
		}

		func attachFrameObserver(to textView: NSTextView) {
			guard frameObserver == nil else { return }
			textView.postsFrameChangedNotifications = true
			frameObserver = NotificationCenter.default.addObserver(
				forName: NSView.frameDidChangeNotification,
				object: textView,
				queue: .main
			) { [weak self] _ in
				MainActor.assumeIsolated {
					guard let self else { return }
					let width = textView.bounds.width
					guard abs(width - self.lastObservedWidth) > 0.5 else { return }
					self.lastObservedWidth = width
					self.applyHorizontalInset(to: textView)
					self.handleWidthChange(in: textView)
				}
			}
		}

		/// Observe the scroll view's clip-view bounds so external scrubbers
		/// (minimaps) can track the visible region. Fires the parent's
		/// `onScrollFractionChanged` callback on every change. Same once-and-done
		/// installation pattern as `attachFrameObserver`.
		func attachScrollObserver(to scrollView: NSScrollView) {
			guard scrollObserver == nil else { return }
			let clipView = scrollView.contentView
			clipView.postsBoundsChangedNotifications = true
			scrollObserver = NotificationCenter.default.addObserver(
				forName: NSView.boundsDidChangeNotification,
				object: clipView,
				queue: .main
			) { [weak self] _ in
				MainActor.assumeIsolated {
					self?.reportScrollFraction()
				}
			}
			// Seed the host with the initial viewport so it doesn't have to
			// wait for the first scroll event to populate the scrubber.
			reportScrollFraction()
		}

		func reportScrollFraction() {
			guard let callback = parent.onScrollFractionChanged,
				  let textView,
				  let scrollView = textView.enclosingScrollView else { return }
			let docHeight = textView.bounds.height
			let visibleHeight = scrollView.contentView.bounds.height
			guard docHeight > 0 else { callback(0, 1); return }
			let topY = scrollView.contentView.bounds.origin.y
			let top = max(0, min(1, topY / docHeight))
			let visible = max(0, min(1, visibleHeight / docHeight))
			callback(top, visible)
		}

		/// Drive the scroll position from outside (e.g. a minimap drag-scrub).
		/// Token-gated so a binding that stays set across unrelated body
		/// re-renders doesn't repeatedly re-scroll: the renderer remembers the
		/// last token it acted on and ignores updates with the same one.
		func handleScrollTarget(in textView: NSTextView) {
			guard let target = parent.scrollTarget,
				  target.token != lastScrollTargetToken else { return }
			lastScrollTargetToken = target.token
			scrollToFraction(target.topFraction, in: textView)
		}

		/// Apply a pixel-based scroll delta from outside (the minimap's
		/// scroll-wheel handler). Same token gating as `handleScrollTarget`.
		func handleScrollDelta(in textView: NSTextView) {
			guard let delta = parent.scrollDelta,
				  delta.token != lastScrollDeltaToken else { return }
			lastScrollDeltaToken = delta.token
			guard let scrollView = textView.enclosingScrollView else { return }
			let docHeight = textView.bounds.height
			let visibleHeight = scrollView.contentView.bounds.height
			let maxY = max(docHeight - visibleHeight, 0)
			let currentY = scrollView.contentView.bounds.origin.y
			let newY = max(0, min(maxY, currentY + delta.deltaY))
			scrollView.contentView.scroll(to: NSPoint(x: 0, y: newY))
			scrollView.reflectScrolledClipView(scrollView.contentView)
			// Same caveat as `scrollToFraction`: NSClipView's programmatic
			// scroll doesn't reliably post the bounds-change notification
			// the scrub observer listens for, and reporting synchronously
			// from updateNSView writes to SwiftUI @State inside an in-flight
			// body evaluation (which gets suppressed). Defer to the next
			// runloop tick.
			DispatchQueue.main.async { [weak self] in self?.reportScrollFraction() }
		}

		/// Scroll so the doc point at `fraction` of the rendered height sits at
		/// the viewport center — keeps the scrubber indicator under the cursor
		/// during a drag (rather than jumping the indicator's top to wherever
		/// the click landed). Clamps to the scrollable range.
		private func scrollToFraction(_ fraction: CGFloat, in textView: NSTextView) {
			guard let scrollView = textView.enclosingScrollView else { return }
			let docHeight = textView.bounds.height
			let visibleHeight = scrollView.contentView.bounds.height
			let maxY = max(docHeight - visibleHeight, 0)
			let centerY = max(0, min(1, fraction)) * docHeight
			let y = max(0, min(maxY, centerY - visibleHeight / 2))
			scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
			scrollView.reflectScrolledClipView(scrollView.contentView)
			// NSClipView.scroll(to:) doesn't reliably post a bounds-change
			// notification, so the scroll-fraction observer the host
			// (e.g. the minimap) relies on doesn't fire on programmatic
			// scrolls. Report explicitly — and defer to the next runloop
			// tick so the SwiftUI @State assignments in the host's
			// callback don't happen inside an in-flight body evaluation
			// (which would cause SwiftUI to suppress them).
			DispatchQueue.main.async { [weak self] in self?.reportScrollFraction() }
		}

		/// Sets the text view's horizontal container inset so the rendered text
		/// column is centered within `parent.contentMaxWidth` (when set), while
		/// the surrounding NSScrollView keeps its full width. This is what keeps
		/// the vertical scroller at the window edge rather than next to the
		/// content column.
		func applyHorizontalInset(to textView: NSTextView) {
			let width = textView.bounds.width
			guard width > 0 else { return }
			let minInset = parent.minimumHorizontalInset
			let inset: CGFloat
			if let maxW = parent.contentMaxWidth, width > maxW {
				inset = max(minInset, (width - maxW) / 2)
			} else {
				inset = minInset
			}
			let changed = abs(textView.textContainerInset.width - inset) > 0.5
			// Only assign when the inset actually moved — the setter
			// invalidates text-container layout regardless of value, which on
			// a no-op reload re-mounts visible attachments and flashes them.
			if changed {
				textView.textContainerInset = NSSize(width: inset, height: 0)
				// availableContentWidth depends on the inset, so container-width
				// attachments (tables) need to re-measure when the inset shifts.
				handleWidthChange(in: textView)
			}
		}

		// Remeasure attachments (tables grow with container; images that just
		// learned their intrinsic size grow to fit it) in place rather than
		// rebuilding the whole textStorage — which avoids the blank flash
		// and lost scroll position when the user resizes the window or an
		// async image dimension lands in the cache.
		private func handleWidthChange(in textView: NSTextView) {
			guard let availableWidth = Self.availableContentWidth(in: textView),
				  let storage = textView.textStorage,
				  let layoutManager = textView.textLayoutManager else { return }
			var didUpdate = false
			let fullRange = NSRange(location: 0, length: storage.length)
			storage.enumerateAttribute(NSAttributedString.Key.attachment, in: fullRange) { value, _, _ in
				guard let attachment = value as? SwiftUIAttachment else { return }
				let target = attachment.usesContainerWidth ? availableWidth : attachment.bounds.size.width
				let previousHeight = attachment.bounds.size.height
				attachment.remeasure(at: target)
				if attachment.bounds.size.height != previousHeight || attachment.usesContainerWidth { didUpdate = true }
			}
			guard didUpdate else { return }
			layoutManager.invalidateLayout(for: layoutManager.documentRange)
			// Force layout fragments to recompute positions BEFORE the viewport
			// pass, otherwise layoutViewport runs against stale positions and
			// any attachment whose Y just shrank into the viewport (e.g. a
			// second table that was below the visible area) doesn't get its
			// hosting view mounted until the next scroll.
			layoutManager.ensureLayout(for: layoutManager.documentRange)
			layoutManager.textViewportLayoutController.layoutViewport()
			textView.needsDisplay = true
		}

		/// Schedules an async parse + build pass against the current text/theme/
		/// fontSize. The synchronous version used to block `updateNSView` —
		/// which kept the document window from appearing at all until the
		/// entire markdown was parsed and every attachment measured. Running
		/// the parse off-main and deferring the build onto a follow-up tick
		/// lets the window present blank immediately and fill in once the
		/// pipeline finishes (typically well under a second for large docs).
		func render(into textView: NSTextView, force: Bool = false) {
			let key = RenderKey(text: parent.text, themeID: parent.theme.signature, fontSize: parent.fontSize, headerToken: parent.headerToken)
			if !force, key == lastRenderKey { return }
			lastRenderKey = key

			renderTask?.cancel()
			let text = parent.text
			let theme = parent.theme
			let fontSize = parent.fontSize
			let baseURL = parent.baseURL
			let header = parent.header
			let progressCallback = parent.onRenderProgress
			let phasesCallback = parent.onRenderPhases
			progressCallback?(0)

			let t0 = CFAbsoluteTimeGetCurrent()
			renderTask = Task { @MainActor [weak self, weak textView] in
				let blocks = await Task.detached(priority: .userInitiated) {
					MarkdownBlockParser.parse(text)
				}.value
				let tAfterParse = CFAbsoluteTimeGetCurrent()
				// Cancelled tasks return silently — the replacement render
				// has already fired its own progress(0). Firing progress(nil)
				// here would briefly drop the overlay between the two
				// renders, producing a visible flash.
				guard !Task.isCancelled, let self, let textView else { return }

				self.prefetchImages(in: blocks, baseURL: baseURL)
				let tAfterPrefetch = CFAbsoluteTimeGetCurrent()

				let availableWidth = Self.availableContentWidth(in: textView)
				let body = await MarkdownAttributedStringBuilder.build(
					blocks: blocks,
					theme: theme,
					fontSize: fontSize,
					baseURL: baseURL,
					availableWidth: availableWidth,
					onProgress: progressCallback
				)
				guard !Task.isCancelled else { return }
				let attributed = NSMutableAttributedString()
				if let header {
					let attachment = SwiftUIAttachment { header }
					attributed.append(NSAttributedString(attachment: attachment))
					attributed.append(NSAttributedString(string: "\n"))
				}
				attributed.append(body)
				let tAfterBuild = CFAbsoluteTimeGetCurrent()

				// Capture the current scroll fraction so a rebuild triggered by
				// a window resize (or any other forced re-render) doesn't snap
				// the user back to the top of the document.
				let scrollFraction = self.currentScrollFraction(of: textView)

				// Fast path: if the rebuilt content matches the existing
				// storage (same attachments in the same positions, identical
				// or near-identical surrounding text), patch the differing
				// text spans in place and leave the attachment NSObjects —
				// and their mounted NSHostingViews — untouched. A full
				// setAttributedString would tear those views down and
				// re-mount them, flashing every visible image on each reload.
				if let storage = textView.textStorage,
				   Self.applyAttributedStringInPlace(attributed, into: storage) {
					progressCallback?(nil)
					let tAfterCommit = CFAbsoluteTimeGetCurrent()
					let fastMetrics = MarkdownAttributedStringBuilder.lastBuildMetrics
					phasesCallback?(MarkdownRenderPhases(
						parse: (tAfterParse - t0) * 1000,
						prefetch: (tAfterPrefetch - tAfterParse) * 1000,
						build: (tAfterBuild - tAfterPrefetch) * 1000,
						commit: (tAfterCommit - tAfterBuild) * 1000,
						initialLayout: 0,
						total: (tAfterCommit - t0) * 1000,
						tookFastPath: true,
						attachMs: fastMetrics?.attachMs,
						attachCount: fastMetrics?.attachCount,
						textMs: fastMetrics?.textMs,
						textCount: fastMetrics?.textCount,
						yieldMs: fastMetrics?.yieldMs,
						parsePreprocessMs: MarkdownBlockParser.lastParseMetrics?.preprocessMs,
						parseDocInitMs: MarkdownBlockParser.lastParseMetrics?.docInitMs,
						parseBlockBuildMs: MarkdownBlockParser.lastParseMetrics?.blockBuildMs,
						parsePostProcessMs: MarkdownBlockParser.lastParseMetrics?.postProcessMs
					))
					self.handleSelectedHeading(in: textView)
					return
				}

				// Hand each already-mounted NSHostingView from the old storage
				// to its same-position counterpart in the new storage. Avoids
				// the flash and viewport-mount race that otherwise follow a
				// setAttributedString call on a doc containing attachments.
				Self.inheritAttachmentHosts(into: attributed, from: textView.textStorage)
				textView.textStorage?.setAttributedString(attributed)
				let tAfterCommit = CFAbsoluteTimeGetCurrent()
				// Render committed — drop the loading overlay before the next
				// runloop tick runs the post-set layout pass.
				progressCallback?(nil)

				// Heading selection might have been requested while the storage
				// was still empty — re-run after content lands so a TOC tap
				// that arrived during the async parse actually scrolls.
				self.handleSelectedHeading(in: textView)

				// TextKit 2 lays out attachments lazily as they scroll into view. On
				// the first render the text view's frame may still be zero, so an
				// immediate layout pass would lay out at 0×0. Defer to the next run
				// loop tick so the scroll view has propagated its real width, then
				// force a full-range layout + viewport pass to realise hosted views.
				//
				// `invalidateLayout` before `ensureLayout` matches what
				// `handleWidthChange` does and is required after a textStorage
				// swap — without it, the layout manager can serve stale fragment
				// positions and the very first attachment (typically a table)
				// fails to mount until the next user scroll forces a re-layout.
				DispatchQueue.main.async { [weak self, weak textView] in
					guard let textView else { return }
					if let layoutManager = textView.textLayoutManager {
						layoutManager.invalidateLayout(for: layoutManager.documentRange)
						layoutManager.ensureLayout(for: layoutManager.documentRange)
						layoutManager.textViewportLayoutController.layoutViewport()
					}
					textView.needsDisplay = true
					if let scrollFraction { self?.restoreScrollFraction(scrollFraction, in: textView) }
					// After scrolling to the user's previous position, re-run
					// the viewport layout so attachments newly inside the
					// visible area get their hosting views mounted.
					textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
					// Document height changed; nudge any scrubber listening on
					// the scroll-fraction callback so it shows the right
					// viewport rectangle without waiting for a user scroll.
					self?.reportScrollFraction()
					let tAfterLayout = CFAbsoluteTimeGetCurrent()
					let fullMetrics = MarkdownAttributedStringBuilder.lastBuildMetrics
					phasesCallback?(MarkdownRenderPhases(
						parse: (tAfterParse - t0) * 1000,
						prefetch: (tAfterPrefetch - tAfterParse) * 1000,
						build: (tAfterBuild - tAfterPrefetch) * 1000,
						commit: (tAfterCommit - tAfterBuild) * 1000,
						initialLayout: (tAfterLayout - tAfterCommit) * 1000,
						total: (tAfterLayout - t0) * 1000,
						tookFastPath: false,
						attachMs: fullMetrics?.attachMs,
						attachCount: fullMetrics?.attachCount,
						textMs: fullMetrics?.textMs,
						textCount: fullMetrics?.textCount,
						yieldMs: fullMetrics?.yieldMs,
						parsePreprocessMs: MarkdownBlockParser.lastParseMetrics?.preprocessMs,
						parseDocInitMs: MarkdownBlockParser.lastParseMetrics?.docInitMs,
						parseBlockBuildMs: MarkdownBlockParser.lastParseMetrics?.blockBuildMs,
						parsePostProcessMs: MarkdownBlockParser.lastParseMetrics?.postProcessMs
					))
				}
				// Belt-and-suspenders: TextKit's first viewport pass can still
				// race with the run loop on cold launches and miss the topmost
				// attachment. Run the layout once more on a later tick — cheap
				// when there's nothing to update, and catches the first table
				// when it has been missed.
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak textView] in
					guard let textView, let layoutManager = textView.textLayoutManager else { return }
					layoutManager.ensureLayout(for: layoutManager.documentRange)
					layoutManager.textViewportLayoutController.layoutViewport()
					textView.needsDisplay = true
				}
			}
		}

		private func currentScrollFraction(of textView: NSTextView) -> CGFloat? {
			guard let scrollView = textView.enclosingScrollView else { return nil }
			let docHeight = textView.bounds.height
			let visibleHeight = scrollView.contentView.bounds.height
			let scrollable = max(docHeight - visibleHeight, 0)
			guard scrollable > 0 else { return 0 }
			return min(max(scrollView.contentView.bounds.origin.y / scrollable, 0), 1)
		}

		private func restoreScrollFraction(_ fraction: CGFloat, in textView: NSTextView) {
			guard let scrollView = textView.enclosingScrollView else { return }
			let docHeight = textView.bounds.height
			let visibleHeight = scrollView.contentView.bounds.height
			let scrollable = max(docHeight - visibleHeight, 0)
			let y = scrollable * fraction
			scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
			scrollView.reflectScrolledClipView(scrollView.contentView)
		}

		// Image dimensions trickle in asynchronously. Rather than rebuilding
		// the entire textStorage — which tears down the first table's
		// already-mounted NSHostingView and frequently fails to remount it
		// without a user scroll — we remeasure container-width attachments
		// in place (the same path `handleWidthChange` uses). Coalesce a
		// few notifications into a single pass so a page full of images
		// doesn't thrash the layout.
		private func scheduleRebuild() {
			rebuildTask?.cancel()
			rebuildTask = Task { @MainActor [weak self] in
				try? await Task.sleep(for: .milliseconds(120))
				guard !Task.isCancelled, let self, let textView else { return }
				self.handleWidthChange(in: textView)
			}
		}

		private func prefetchImages(in blocks: [MarkdownBlock], baseURL: URL?) {
			for block in blocks {
				switch block {
				case .image(let source, _, _, _, _):
					if let url = Self.resolve(source, baseURL: baseURL) {
						ImageDimensionCache.shared.prefetchSyncIfLocal(url)
						ImageDimensionCache.shared.prefetch(url)
					}
				case .imageRow(let images, _):
					for img in images {
						if let url = Self.resolve(img.source, baseURL: baseURL) {
							ImageDimensionCache.shared.prefetchSyncIfLocal(url)
							ImageDimensionCache.shared.prefetch(url)
						}
					}
				case .figure(let item, _, _):
					if let url = Self.resolve(item.source, baseURL: baseURL) {
						ImageDimensionCache.shared.prefetchSyncIfLocal(url)
						ImageDimensionCache.shared.prefetch(url)
					}
				case .table(let header, let rows, _, _):
					for cell in header {
						if let url = imageURL(from: cell, baseURL: baseURL) {
							ImageDimensionCache.shared.prefetchSyncIfLocal(url)
							ImageDimensionCache.shared.prefetch(url)
						}
					}
					for row in rows {
						for cell in row {
							if let url = imageURL(from: cell, baseURL: baseURL) {
								ImageDimensionCache.shared.prefetchSyncIfLocal(url)
								ImageDimensionCache.shared.prefetch(url)
							}
						}
					}
				case .blockquote(let children, _),
					 .details(_, let children, _),
					 .alert(_, let children, _):
					prefetchImages(in: children, baseURL: baseURL)
				case .aligned(_, let inner, _):
					prefetchImages(in: [inner], baseURL: baseURL)
				case .orderedList(let items, _, _), .unorderedList(let items, _):
					for item in items {
						prefetchImages(in: item.blocks, baseURL: baseURL)
					}
				default:
					break
				}
			}
		}

		private func imageURL(from cell: TableCell, baseURL: URL?) -> URL? {
			guard case let .image(source, _, _, _, _) = cell else { return nil }
			return Self.resolve(source, baseURL: baseURL)
		}

		/// Scroll to the heading the TOC just selected, if its value changed
		/// since the last pass. The binding's value is `"<index>-<text>\t<tap>"`
		/// — we need only the integer index to walk the rendered storage and
		/// find the matching heading run, because raw-markdown offsets don't
		/// line up with the rendered attributed string (`#` markers are gone,
		/// inline-formatting tokens are stripped, etc).
		func handleSelectedHeading(in textView: NSTextView) {
			let current = parent.selectedHeadingID?.wrappedValue
			guard current != lastSelectedHeading else { return }
			lastSelectedHeading = current
			guard let value = current else { return }
			let id = value.components(separatedBy: "\t").first ?? value
			guard let dash = id.firstIndex(of: "-"),
				  let index = Int(id[..<dash]),
				  let storage = textView.textStorage,
				  let range = Self.range(ofHeadingAt: index, in: storage) else { return }
			textView.scrollRangeToVisible(range)
			flashHeading(range: range, in: textView)
			// `scrollRangeToVisible` reaches the clipView through the same
			// programmatic path that doesn't reliably post the bounds-change
			// notification, so the scrub observer wouldn't fire and the
			// minimap's viewport indicator would stay where it was. Report
			// explicitly on the next runloop tick.
			DispatchQueue.main.async { [weak self] in self?.reportScrollFraction() }
		}

		private static func range(ofHeadingAt targetIndex: Int, in storage: NSTextStorage) -> NSRange? {
			var seen = 0
			var found: NSRange?
			storage.enumerateAttribute(.markdownHeadingLevel, in: NSRange(location: 0, length: storage.length), options: []) { value, range, stop in
				guard value != nil else { return }
				if seen == targetIndex {
					found = range
					stop.pointee = true
					return
				}
				seen += 1
			}
			return found
		}

		/// Briefly tint the heading line so the user can locate it after the
		/// scroll. Captures any existing backgroundColor runs (e.g. inline
		/// code) in the range so we restore them rather than wiping them on
		/// cleanup.
		private func flashHeading(range: NSRange, in textView: NSTextView) {
			flashTask?.cancel()
			guard let storage = textView.textStorage,
				  let initial = range.intersection(NSRange(location: 0, length: storage.length)),
				  initial.length > 0 else { return }
			var preexisting: [(NSRange, NSColor?)] = []
			storage.enumerateAttribute(.backgroundColor, in: initial, options: []) { value, subRange, _ in
				preexisting.append((subRange, value as? NSColor))
			}
			storage.addAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.18), range: initial)
			flashTask = Task { @MainActor [weak self, weak textView] in
				try? await Task.sleep(for: .milliseconds(600))
				guard !Task.isCancelled, let storage = textView?.textStorage else { return }
				let docRange = NSRange(location: 0, length: storage.length)
				for (subRange, color) in preexisting {
					guard let clamped = subRange.intersection(docRange), clamped.length > 0 else { continue }
					if let color {
						storage.addAttribute(.backgroundColor, value: color, range: clamped)
					} else {
						storage.removeAttribute(.backgroundColor, range: clamped)
					}
				}
				self?.flashTask = nil
			}
		}

		// Reading width inside the text container: textView width minus the
		// horizontal text-container inset on each side and the line-fragment
		// padding on each side. Falls back to nil before the view has laid
		// out (so SwiftUIAttachment uses its default measurement width).
		/// Called from `MarkdownTextViewBacking.layout()`. Runs an extra
		/// viewport-layout pass — TextKit's initial pass can race past
		/// `setAttributedString` without ever asking the attachment view
		/// providers for views — and schedules a 50ms follow-up safety net
		/// for the case where even the inline pass misses the first batch
		/// of in-viewport attachments. Cheap when everything is already
		/// mounted; recovers visible images on the unlucky cold-open races.
		func didLayoutTextView(_ textView: NSTextView) {
			guard textView.bounds.width > 0,
				  let layoutManager = textView.textLayoutManager else { return }
			layoutManager.textViewportLayoutController.layoutViewport()
			remountTask?.cancel()
			remountTask = Task { @MainActor [weak self, weak textView] in
				try? await Task.sleep(for: .milliseconds(50))
				guard !Task.isCancelled, let self, let textView else { return }
				self.remountAttachmentsIfNeeded(in: textView)
			}
		}

		/// If an attachment *currently in the viewport* hasn't been mounted yet,
		/// run a viewport-layout pass to nudge TextKit into asking its view
		/// provider for a view. Scoped to the viewport on purpose: below-the-fold
		/// attachments are unmounted by design, so a document-wide scan reports
		/// "unmounted" on essentially every scroll-driven layout — and the old
		/// `ensureLayout(documentRange)` it then ran re-laid-out the entire
		/// document many times per second, which is what made table/image-heavy
		/// docs scroll jerkily. Walking only the already-laid-out fragments
		/// between the viewport's top and bottom keeps this cheap and never
		/// forces layout of off-screen content.
		private func remountAttachmentsIfNeeded(in textView: NSTextView) {
			guard let storage = textView.textStorage,
				  let layoutManager = textView.textLayoutManager,
				  let contentManager = layoutManager.textContentManager else { return }
			let viewport = layoutManager.textViewportLayoutController.viewportBounds
			guard let topFragment = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: viewport.minY)) else { return }
			let docStart = contentManager.documentRange.location
			var hasUnmounted = false
			layoutManager.enumerateTextLayoutFragments(from: topFragment.rangeInElement.location, options: []) { fragment in
				guard fragment.layoutFragmentFrame.minY <= viewport.maxY else { return false }
				let start = contentManager.offset(from: docStart, to: fragment.rangeInElement.location)
				let length = contentManager.offset(from: fragment.rangeInElement.location, to: fragment.rangeInElement.endLocation)
				guard length > 0, start >= 0, start + length <= storage.length else { return true }
				storage.enumerateAttribute(.attachment, in: NSRange(location: start, length: length)) { value, _, stop in
					guard let attachment = value as? SwiftUIAttachment, !attachment.isMounted else { return }
					hasUnmounted = true
					stop.pointee = true
				}
				return !hasUnmounted
			}
			guard hasUnmounted else { return }
			layoutManager.textViewportLayoutController.layoutViewport()
			textView.needsDisplay = true
		}

		/// For each SwiftUIAttachment in `new` whose ordinal position matches
		/// one in `old`, transfer the old attachment's mounted NSHostingView
		/// onto the new attachment (refreshing its rootView with the new
		/// content). Positional pairing is enough because a theme-only
		/// rebuild produces the same attachment count and order as before.
		fileprivate static func inheritAttachmentHosts(into new: NSAttributedString, from old: NSTextStorage?) {
			guard let old else { return }
			let previous = attachments(in: old)
			guard !previous.isEmpty else { return }
			let upcoming = attachments(in: new)
			for (incoming, prior) in zip(upcoming, previous) {
				incoming.inheritHost(from: prior)
			}
		}

		private static func attachments(in string: NSAttributedString) -> [SwiftUIAttachment] {
			var result: [SwiftUIAttachment] = []
			string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string.length)) { value, _, _ in
				if let attachment = value as? SwiftUIAttachment { result.append(attachment) }
			}
			return result
		}

		/// Apply `new` to `storage` by editing only the text spans between
		/// attachments, leaving the attachment NSObjects (and their mounted
		/// hosting views) in place. Returns `false` — so the caller falls
		/// back to `setAttributedString` — when the attachment shape changed
		/// (different count, a non-SwiftUIAttachment, or any pair whose
		/// `contentKey` differs).
		fileprivate static func applyAttributedStringInPlace(_ new: NSAttributedString, into storage: NSTextStorage) -> Bool {
			guard case let .clean(oldSlots) = attachmentScan(of: storage),
				  case let .clean(newSlots) = attachmentScan(of: new),
				  oldSlots.count == newSlots.count else { return false }
			for (oldSlot, newSlot) in zip(oldSlots, newSlots) {
				guard let oldKey = oldSlot.attachment.contentKey,
					  let newKey = newSlot.attachment.contentKey,
					  oldKey == newKey else { return false }
			}

			// One text span per gap: before the first attachment, between
			// each consecutive pair, and after the last.
			var spans: [(old: NSRange, new: NSRange)] = []
			var oldCursor = 0
			var newCursor = 0
			for (oldSlot, newSlot) in zip(oldSlots, newSlots) {
				spans.append((
					NSRange(location: oldCursor, length: oldSlot.location - oldCursor),
					NSRange(location: newCursor, length: newSlot.location - newCursor)
				))
				oldCursor = oldSlot.location + 1
				newCursor = newSlot.location + 1
			}
			spans.append((
				NSRange(location: oldCursor, length: storage.length - oldCursor),
				NSRange(location: newCursor, length: new.length - newCursor)
			))

			// Narrow each changed span to the smallest differing sub-range so
			// layout invalidation stays away from attachment lines where
			// possible. Skip spans whose visible text is identical — only the
			// attribute objects churn there, which is invisible.
			struct Edit { let range: NSRange; let replacement: NSAttributedString }
			var edits: [Edit] = []
			for span in spans {
				let oldAttr = storage.attributedSubstring(from: span.old)
				let newAttr = new.attributedSubstring(from: span.new)
				if oldAttr.string == newAttr.string { continue }
				let (innerOld, innerNew) = innerDiffRange(oldText: oldAttr.string, newText: newAttr.string)
				let range = NSRange(location: span.old.location + innerOld.location, length: innerOld.length)
				edits.append(Edit(range: range, replacement: newAttr.attributedSubstring(from: innerNew)))
			}

			guard !edits.isEmpty else { return true }

			storage.beginEditing()
			for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
				storage.replaceCharacters(in: edit.range, with: edit.replacement)
			}
			storage.endEditing()
			return true
		}

		private enum AttachmentScan {
			case clean([(attachment: SwiftUIAttachment, location: Int)])
			/// Storage contained an attachment we can't reason about (not a
			/// SwiftUIAttachment, or a multi-character attachment range).
			case unsupported
		}

		private static func attachmentScan(of str: NSAttributedString) -> AttachmentScan {
			var slots: [(attachment: SwiftUIAttachment, location: Int)] = []
			var unsupported = false
			str.enumerateAttribute(.attachment, in: NSRange(location: 0, length: str.length)) { value, range, _ in
				guard let value else { return }
				if let attachment = value as? SwiftUIAttachment, range.length == 1 {
					slots.append((attachment, range.location))
				} else {
					unsupported = true
				}
			}
			return unsupported ? .unsupported : .clean(slots)
		}

		/// Smallest sub-range whose characters differ between `oldText` and
		/// `newText` — strips the longest matching prefix and suffix.
		private static func innerDiffRange(oldText: String, newText: String) -> (NSRange, NSRange) {
			let oldChars = Array(oldText.utf16)
			let newChars = Array(newText.utf16)
			let minLen = min(oldChars.count, newChars.count)
			var prefix = 0
			while prefix < minLen && oldChars[prefix] == newChars[prefix] { prefix += 1 }
			var suffix = 0
			let suffixCap = min(oldChars.count - prefix, newChars.count - prefix)
			while suffix < suffixCap
					&& oldChars[oldChars.count - 1 - suffix] == newChars[newChars.count - 1 - suffix] {
				suffix += 1
			}
			return (
				NSRange(location: prefix, length: oldChars.count - prefix - suffix),
				NSRange(location: prefix, length: newChars.count - prefix - suffix)
			)
		}

		private static func availableContentWidth(in textView: NSTextView) -> CGFloat? {
			let width = textView.bounds.width
			guard width > 0 else { return nil }
			let inset = textView.textContainerInset.width * 2
			let padding = (textView.textContainer?.lineFragmentPadding ?? 0) * 2
			let usable = width - inset - padding
			return usable > 0 ? usable : nil
		}

		private static func resolve(_ source: String, baseURL: URL?) -> URL? {
			if let url = URL(string: source), url.scheme != nil { return url }
			if let base = baseURL, let url = URL(string: source, relativeTo: base) { return url }
			return URL(string: source)
		}

		public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
			let url: URL? = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
			guard let url else { return false }
			if handleFootnoteJump(url: url, in: textView) { return true }
			NSWorkspace.shared.open(url)
			return true
		}

		/// Footnotes link both directions: `footnote://id` (the reference)
		/// jumps to `footnote-anchor://id` (the body opener), and
		/// `footnote-back://id` (the trailing ↩) jumps back to the reference.
		/// Returns true when the URL was a footnote link we handled.
		private func handleFootnoteJump(url: URL, in textView: NSTextView) -> Bool {
			guard let scheme = url.scheme, let host = url.host else { return false }
			let targetScheme: String
			switch scheme {
			case "footnote":      targetScheme = "footnote-anchor"
			case "footnote-back": targetScheme = "footnote"
			default: return false
			}
			guard let target = locationOfLink(scheme: targetScheme, host: host, in: textView) else { return true }
			textView.scrollRangeToVisible(NSRange(location: target, length: 0))
			return true
		}

		private func locationOfLink(scheme: String, host: String, in textView: NSTextView) -> Int? {
			guard let storage = textView.textStorage else { return nil }
			var found: Int?
			storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
				let url: URL? = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
				guard let url, url.scheme == scheme, url.host == host else { return }
				found = range.location
				stop.pointee = true
			}
			return found
		}
	}

	struct RenderKey: Equatable {
		let text: String
		let themeID: String
		let fontSize: CGFloat
		let headerToken: AnyHashable?
	}
}

/// Per-phase wall-clock timings for a render pass, in milliseconds. Emitted
/// through `MarkdownTextView.onRenderPhases` for benchmarking; not meant to
/// drive product behavior.
public struct MarkdownRenderPhases: Sendable {
	public let parse: Double
	public let prefetch: Double
	public let build: Double
	public let commit: Double
	public let initialLayout: Double
	public let total: Double
	public let tookFastPath: Bool
	/// Build-time breakdown by block category (sourced from
	/// `MarkdownAttributedStringBuilder.lastBuildMetrics`). Nil when no
	/// metrics were captured (defensive — should never happen on the full
	/// render path).
	public let attachMs: Double?
	public let attachCount: Int?
	public let textMs: Double?
	public let textCount: Int?
	public let yieldMs: Double?
	/// Parse sub-phases (preprocess / Document init / block build /
	/// post-process). Sourced from `MarkdownBlockParser.lastParseMetrics`.
	public let parsePreprocessMs: Double?
	public let parseDocInitMs: Double?
	public let parseBlockBuildMs: Double?
	public let parsePostProcessMs: Double?
}

/// A scroll request expressed as a fraction of the document's rendered height,
/// paired with a token. The token is what makes the request distinct across
/// state-driven callers — two updates with the same `topFraction` but
/// different tokens both fire, while repeating an unchanged target is a no-op.
/// A relative scroll request expressed in pixels (positive deltaY scrolls
/// content down), paired with a token so two updates with the same delta
/// across separate gestures both fire.
public struct MarkdownScrollDelta: Equatable, Sendable {
	public let deltaY: CGFloat
	public let token: Int

	public init(deltaY: CGFloat, token: Int) {
		self.deltaY = deltaY
		self.token = token
	}
}

public struct MarkdownScrollTarget: Equatable, Sendable {
	public let topFraction: CGFloat
	public let token: Int

	public init(topFraction: CGFloat, token: Int) {
		self.topFraction = topFraction
		self.token = token
	}
}

/// NSTextView subclass that surfaces hovered link URLs through `onLinkHover`.
/// macOS's built-in `.link` attribute already produces the hand cursor and a
/// system tooltip; this adds a callback so we can also show the URL in our
/// status bar.
final class MarkdownTextViewBacking: NSTextView {
	var onLinkHover: ((String?) -> Void)?
	/// Fired after AppKit lays out the text view. The coordinator uses this
	/// to run an additional viewport-layout pass — TextKit 2's
	/// `layoutViewport()` invoked from the deferred dispatch right after
	/// `setAttributedString` can miss the topmost attachment when the text
	/// view's frame is still settling. Hooking AppKit's layout cycle
	/// guarantees we get a pass at a moment when the view actually has a
	/// valid frame in a window.
	var onDidLayout: (() -> Void)?
	/// Tint used for the blockquote indicator bar. Set by the coordinator
	/// from the active theme so the bar matches link/accent colour rather
	/// than the secondary text tone.
	var blockquoteBarColor: NSColor = NSColor.controlAccentColor
	private var hoverTrackingArea: NSTrackingArea?
	private var lastReportedURL: String?

	override func layout() {
		super.layout()
		onDidLayout?()
	}

	override func drawBackground(in rect: NSRect) {
		super.drawBackground(in: rect)
		drawBlockquoteBars(in: rect)
	}

	private func drawBlockquoteBars(in rect: NSRect) {
		guard let storage = textStorage,
			  let layoutManager = textLayoutManager,
			  let contentManager = layoutManager.textContentManager,
			  storage.length > 0 else { return }

		let insetX = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0)
		let fullRange = NSRange(location: 0, length: storage.length)
		storage.enumerateAttribute(.markdownBlockquoteDepth, in: fullRange) { value, range, _ in
			guard let depth = value as? Int, depth > 0,
				  let textRange = self.textRange(for: range, in: contentManager) else { return }

			let barWidth: CGFloat = 4
			let barSpacing: CGFloat = 16
			let barX = insetX + CGFloat(depth - 1) * barSpacing
			layoutManager.enumerateTextLayoutFragments(from: textRange.location, options: []) { fragment in
				guard fragment.rangeInElement.intersection(textRange) != nil else {
					return fragment.rangeInElement.endLocation.compare(textRange.endLocation) == .orderedAscending
				}
				let frame = fragment.layoutFragmentFrame
				let barRect = NSRect(x: barX, y: frame.minY, width: barWidth, height: frame.height)
				if barRect.intersects(rect) {
					self.blockquoteBarColor.withAlphaComponent(0.65).setFill()
					NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5).fill()
				}
				return fragment.rangeInElement.endLocation.compare(textRange.endLocation) == .orderedAscending
			}
		}
	}

	private func textRange(for nsRange: NSRange, in contentManager: NSTextContentManager) -> NSTextRange? {
		guard let start = contentManager.location(contentManager.documentRange.location, offsetBy: nsRange.location),
			  let end = contentManager.location(start, offsetBy: nsRange.length) else { return nil }
		return NSTextRange(location: start, end: end)
	}

	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		if let existing = hoverTrackingArea {
			removeTrackingArea(existing)
			hoverTrackingArea = nil
		}
		let area = NSTrackingArea(
			rect: .zero,
			options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
			owner: self,
			userInfo: nil
		)
		addTrackingArea(area)
		hoverTrackingArea = area
	}

	override func mouseMoved(with event: NSEvent) {
		super.mouseMoved(with: event)
		reportLink(at: convert(event.locationInWindow, from: nil))
	}

	override func mouseExited(with event: NSEvent) {
		super.mouseExited(with: event)
		clearReportedURL()
	}

	private func reportLink(at point: NSPoint) {
		guard let storage = textStorage, storage.length > 0 else {
			clearReportedURL(); return
		}
		let index = characterIndexForInsertion(at: point)
		guard index >= 0, index < storage.length else {
			clearReportedURL(); return
		}
		let attr = storage.attribute(.link, at: index, effectiveRange: nil)
		let urlString: String?
		switch attr {
		case let url as URL: urlString = url.absoluteString
		case let s as String: urlString = s
		default: urlString = nil
		}
		if urlString != lastReportedURL {
			lastReportedURL = urlString
			onLinkHover?(urlString)
		}
	}

	private func clearReportedURL() {
		guard lastReportedURL != nil else { return }
		lastReportedURL = nil
		onLinkHover?(nil)
	}
}

extension MarkdownTheme {
	/// Cheap identity key for memoizing renders. Theme is Equatable but using
	/// a tag avoids comparing Color values per scroll. Must include every
	/// field that influences the produced NSAttributedString, otherwise an
	/// edit that only changes that field (e.g. fontFamily in the Theme
	/// Builder) gets short-circuited by the render cache.
	var signature: String {
		"\(textColor.hashValue)|\(linkColor.hashValue)|\(codeBackground.hashValue)|\(codeForeground.hashValue)|\(secondaryColor.hashValue)|\(backgroundColor.hashValue)|\(headingColor.hashValue)|\(alternateRowBackground?.hashValue ?? 0)|\(fontFamily.rawValue)"
	}
}
#endif
