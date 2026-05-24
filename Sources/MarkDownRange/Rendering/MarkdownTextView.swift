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
	/// Maximum width of the rendered text column. The scroll view still fills
	/// the parent (so its scroller stays at the window edge); the inset of
	/// the underlying NSTextView is adjusted to center the text within this
	/// width. `nil` means no constraint (text fills the available width).
	public var contentMaxWidth: CGFloat?
	/// Minimum horizontal inset to keep around the text column even when the
	/// content has no width constraint. Default 24.
	public var minimumHorizontalInset: CGFloat = 24
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
		textView.onDidLayout = { [weak textView] in
			guard let textView,
				  textView.window != nil,
				  textView.bounds.width > 0,
				  let layoutManager = textView.textLayoutManager
			else { return }
			layoutManager.textViewportLayoutController.layoutViewport()
		}
		return scrollView
	}

	public func updateNSView(_ scrollView: NSScrollView, context: Context) {
		guard let textView = scrollView.documentView as? NSTextView else { return }
		context.coordinator.parent = self
		scrollView.backgroundColor = NSColor(theme.backgroundColor)
		textView.backgroundColor = NSColor(theme.backgroundColor)
		if let backing = textView as? MarkdownTextViewBacking {
			backing.blockquoteBarColor = NSColor(theme.linkColor)
		}
		context.coordinator.attachFrameObserver(to: textView)
		context.coordinator.applyHorizontalInset(to: textView)
		context.coordinator.render(into: textView)
	}

	public func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

	@MainActor
	public final class Coordinator: NSObject, NSTextViewDelegate {
		var parent: MarkdownTextView
		weak var textView: NSTextView?
		var lastRenderKey: RenderKey?
		private var cacheToken: UUID?
		private var rebuildTask: Task<Void, Never>?
		private var lastObservedWidth: CGFloat = 0
		private var frameObserver: NSObjectProtocol?

		init(parent: MarkdownTextView) {
			self.parent = parent
			super.init()
			cacheToken = ImageDimensionCache.shared.subscribe { [weak self] in
				Task { @MainActor [weak self] in self?.scheduleRebuild() }
			}
		}

		deinit {
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
			textView.textContainerInset = NSSize(width: inset, height: 0)
			if changed {
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

		func render(into textView: NSTextView, force: Bool = false) {
			let key = RenderKey(text: parent.text, themeID: parent.theme.signature, fontSize: parent.fontSize, headerToken: parent.headerToken)
			if !force, key == lastRenderKey { return }
			lastRenderKey = key

			let blocks = MarkdownBlockParser.parse(parent.text)
			prefetchImages(in: blocks, baseURL: parent.baseURL)

			let availableWidth = Self.availableContentWidth(in: textView)
			let body = MarkdownAttributedStringBuilder.build(blocks: blocks, theme: parent.theme, fontSize: parent.fontSize, baseURL: parent.baseURL, availableWidth: availableWidth)
			let attributed = NSMutableAttributedString()
			if let header = parent.header {
				let attachment = SwiftUIAttachment { header }
				attributed.append(NSAttributedString(attachment: attachment))
				attributed.append(NSAttributedString(string: "\n"))
			}
			attributed.append(body)

			// Capture the current scroll fraction so a rebuild triggered by
			// a window resize (or any other forced re-render) doesn't snap
			// the user back to the top of the document.
			let scrollFraction = currentScrollFraction(of: textView)
			// Hand each already-mounted NSHostingView from the old storage
			// to its same-position counterpart in the new storage. Avoids
			// the flash and viewport-mount race that otherwise follow a
			// setAttributedString call on a doc containing attachments.
			Self.inheritAttachmentHosts(into: attributed, from: textView.textStorage)
			textView.textStorage?.setAttributedString(attributed)

			// TextKit 2 lays out attachments lazily as they scroll into view. On
			// the first render the text view's frame may still be zero, so an
			// immediate layout pass would lay out at 0×0. Defer to the next run
			// loop tick so the scroll view has propagated its real width, then
			// force a full-range layout + viewport pass to realise hosted views.
			//be
			// `invalidateLayout` before `ensureLayout` matches what
			// `handleWidthChange` does and is required after a textStorage
			// swap — without it, the layout manager can serve stale fragment
			// positions and the very first attachment (typically a table)
			// fails to mount until the next user scroll forces a re-layout.
			DispatchQueue.main.async { [weak self] in
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

		// Reading width inside the text container: textView width minus the
		// horizontal text-container inset on each side and the line-fragment
		// padding on each side. Falls back to nil before the view has laid
		// out (so SwiftUIAttachment uses its default measurement width).
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

private extension MarkdownTheme {
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
