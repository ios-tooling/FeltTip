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

		let key = RenderKey(text: text, themeID: theme.signature, fontSize: fontSize, headerToken: headerToken)
		guard key != context.coordinator.lastRenderKey else { return }
		context.coordinator.lastRenderKey = key

		let blocks = MarkdownBlockParser.parse(text)
		let body = MarkdownAttributedStringBuilder.build(blocks: blocks, theme: theme, fontSize: fontSize, baseURL: baseURL)
		let attributed = NSMutableAttributedString()
		if let header {
			let attachment = SwiftUIAttachment { header }
			attributed.append(NSAttributedString(attachment: attachment))
			attributed.append(NSAttributedString(string: "\n"))
		}
		attributed.append(body)
		textView.textStorage?.setAttributedString(attributed)

		// TextKit 2 lays out attachments lazily as they scroll into view. On
		// the first render the text view's frame may still be zero, so an
		// immediate layout pass would lay out at 0×0. Defer to the next run
		// loop tick so the scroll view has propagated its real width, then
		// force a full-range layout + viewport pass to realise hosted views.
		DispatchQueue.main.async {
			if let layoutManager = textView.textLayoutManager {
				layoutManager.ensureLayout(for: layoutManager.documentRange)
				layoutManager.textViewportLayoutController.layoutViewport()
			}
			textView.needsDisplay = true
		}
	}

	public func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

	@MainActor
	public final class Coordinator: NSObject, NSTextViewDelegate {
		var parent: MarkdownTextView
		weak var textView: NSTextView?
		var lastRenderKey: RenderKey?

		init(parent: MarkdownTextView) { self.parent = parent }

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
