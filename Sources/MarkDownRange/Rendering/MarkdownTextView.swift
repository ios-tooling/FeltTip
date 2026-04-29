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

	public init(text: String, theme: MarkdownTheme, fontSize: CGFloat, baseURL: URL? = nil) {
		self.text = text
		self.theme = theme
		self.fontSize = fontSize
		self.baseURL = baseURL
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
		// Keep horizontal inset for readable line length; let the SwiftUI parent
		// own vertical spacing so it composes cleanly with surrounding chrome.
		textView.textContainerInset = NSSize(width: 24, height: 0)
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
		return scrollView
	}

	public func updateNSView(_ scrollView: NSScrollView, context: Context) {
		guard let textView = scrollView.documentView as? NSTextView else { return }
		context.coordinator.parent = self
		scrollView.backgroundColor = NSColor(theme.backgroundColor)
		textView.backgroundColor = NSColor(theme.backgroundColor)
		context.coordinator.attachFrameObserver(to: textView)
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
					self.scheduleRebuild()
				}
			}
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
			textView.textStorage?.setAttributedString(attributed)

			// TextKit 2 lays out attachments lazily as they scroll into view. On
			// the first render the text view's frame may still be zero, so an
			// immediate layout pass would lay out at 0×0. Defer to the next run
			// loop tick so the scroll view has propagated its real width, then
			// force a full-range layout + viewport pass to realise hosted views.
			DispatchQueue.main.async { [weak self] in
				if let layoutManager = textView.textLayoutManager {
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

		// Image dimensions trickle in asynchronously; coalesce a few notifications
		// into one rebuild so a page full of images doesn't thrash the layout.
		private func scheduleRebuild() {
			rebuildTask?.cancel()
			rebuildTask = Task { @MainActor [weak self] in
				try? await Task.sleep(for: .milliseconds(60))
				guard !Task.isCancelled, let self, let textView else { return }
				self.render(into: textView, force: true)
			}
		}

		private func prefetchImages(in blocks: [MarkdownBlock], baseURL: URL?) {
			for block in blocks {
				switch block {
				case .image(let source, _, _, _, _):
					if let url = Self.resolve(source, baseURL: baseURL) {
						ImageDimensionCache.shared.prefetch(url)
					}
				case .imageRow(let images, _):
					for img in images {
						if let url = Self.resolve(img.source, baseURL: baseURL) {
							ImageDimensionCache.shared.prefetch(url)
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

		// Reading width inside the text container: textView width minus the
		// horizontal text-container inset on each side and the line-fragment
		// padding on each side. Falls back to nil before the view has laid
		// out (so SwiftUIAttachment uses its default measurement width).
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
			NSWorkspace.shared.open(url)
			return true
		}
	}

	struct RenderKey: Equatable {
		let text: String
		let themeID: String
		let fontSize: CGFloat
		let headerToken: AnyHashable?
	}
}

/// NSTextView subclass with no special behavior yet — placeholder for future
/// hooks (focus mode shading, section flash highlights, etc.).
final class MarkdownTextViewBacking: NSTextView {}

private extension MarkdownTheme {
	/// Cheap identity key for memoizing renders. Theme is Equatable but using
	/// a tag avoids comparing Color values per scroll.
	var signature: String {
		"\(textColor.hashValue)|\(linkColor.hashValue)|\(codeBackground.hashValue)|\(codeForeground.hashValue)|\(secondaryColor.hashValue)|\(backgroundColor.hashValue)|\(headingColor.hashValue)"
	}
}
#endif
