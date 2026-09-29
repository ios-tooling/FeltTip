//
//  MarkdownInstantPreview.swift
//  FeltTip
//
//  A deliberately lightweight native first surface for a styled document.
//  It renders selectable attributed text while the full editable WKWebView
//  starts behind it, avoiding WebContent process startup on the first-frame
//  critical path. It is not a second source editor: Markdown remains the source
//  of truth and the host replaces this view as soon as WebKit is interactive.
//

#if os(macOS)
@preconcurrency import AppKit
import SwiftUI

public struct MarkdownInstantPreview: NSViewRepresentable {
	let text: String
	let theme: MarkdownTheme
	let fontSize: CGFloat
	var initialScrollFraction: Double?
	var onReady: (@MainActor @Sendable () -> Void)?
	var onScrollFractionChanged: (@MainActor @Sendable (Double) -> Void)?
	var onSourceSelectionChanged: ((NSRange?) -> Void)?

	public init(text: String, theme: MarkdownTheme, fontSize: CGFloat) {
		self.text = text
		self.theme = theme
		self.fontSize = fontSize
	}

	public func initialScrollFraction(_ fraction: Double?) -> Self {
		var copy = self
		copy.initialScrollFraction = fraction
		return copy
	}

	public func onReady(_ callback: @escaping @MainActor @Sendable () -> Void) -> Self {
		var copy = self
		copy.onReady = callback
		return copy
	}

	public func onScrollFractionChanged(
		_ callback: @escaping @MainActor @Sendable (Double) -> Void
	) -> Self {
		var copy = self
		copy.onScrollFractionChanged = callback
		return copy
	}

	public func onSourceSelectionChanged(_ callback: @escaping (NSRange?) -> Void) -> Self {
		var copy = self
		copy.onSourceSelectionChanged = callback
		return copy
	}

	public func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

	/// Pure rendering seam for regression and performance tests. Production
	/// callers should use the view so TextKit owns layout and selection.
	static func renderForTesting(
		_ markdown: String, theme: MarkdownTheme = .default, fontSize: CGFloat = 16
	) -> NSAttributedString {
		InstantAttributedRenderer.render(markdown, theme: theme, fontSize: fontSize)
	}

	static func renderLaunchForTesting(
		_ markdown: String, theme: MarkdownTheme = .default, fontSize: CGFloat = 16
	) -> NSAttributedString {
		InstantAttributedRenderer.renderLaunch(markdown, theme: theme, fontSize: fontSize)
	}

	/// Builds the native preview without a SwiftUI hosting controller. Launch-time
	/// callers can install this directly in an AppKit window, avoiding the cost of
	/// constructing a second SwiftUI scene before the document scene exists.
	@MainActor
	public static func makeAppKitView(
		text: String,
		theme: MarkdownTheme,
		fontSize: CGFloat,
		onReady: @escaping @MainActor @Sendable () -> Void
	) -> NSScrollView {
		let rendered = InstantAttributedRenderer.renderLaunch(
			text, theme: theme, fontSize: fontSize)
		let (scrollView, textView) = makeSurface(
			rendered: rendered, theme: theme)
		textView.onAttached = onReady
		return scrollView
	}

	public func makeNSView(context: Context) -> NSScrollView {
		let rendered = InstantAttributedRenderer.render(
			text, theme: theme, fontSize: fontSize)
		let (scrollView, textView) = Self.makeSurface(
			rendered: rendered, theme: theme)
		textView.delegate = context.coordinator
		textView.onAttached = { [weak coordinator = context.coordinator] in
			coordinator?.didAttach()
		}
		context.coordinator.attach(scrollView: scrollView, textView: textView)
		return scrollView
	}

	private static func makeSurface(
		rendered: NSAttributedString, theme: MarkdownTheme
	) -> (NSScrollView, InstantPreviewTextView) {
		let scrollView = NSScrollView()
		scrollView.hasVerticalScroller = true
		scrollView.hasHorizontalScroller = false
		scrollView.autohidesScrollers = true
		scrollView.borderType = .noBorder
		scrollView.drawsBackground = true
		scrollView.backgroundColor = NSColor(theme.backgroundColor)
		scrollView.contentView.postsBoundsChangedNotifications = true

		let textView = InstantPreviewTextView(frame: .zero)
		textView.setAccessibilityIdentifier("instant-styled-preview")
		textView.isEditable = false
		textView.isSelectable = true
		textView.drawsBackground = false
		textView.usesFindBar = true
		textView.isIncrementalSearchingEnabled = true
		textView.textContainerInset = NSSize(width: 28, height: 18)
		textView.isVerticallyResizable = true
		textView.isHorizontallyResizable = false
		textView.autoresizingMask = [.width]
		textView.minSize = .zero
		textView.maxSize = NSSize(
			width: CGFloat.greatestFiniteMagnitude,
			height: CGFloat.greatestFiniteMagnitude)
		textView.textContainer?.widthTracksTextView = true
		textView.textContainer?.containerSize = NSSize(
			width: 0, height: CGFloat.greatestFiniteMagnitude)
		textView.layoutManager?.allowsNonContiguousLayout = true
		textView.textStorage?.setAttributedString(rendered)
		scrollView.documentView = textView
		return (scrollView, textView)
	}

	public func updateNSView(_ scrollView: NSScrollView, context: Context) {
		context.coordinator.parent = self
		let color = NSColor(theme.backgroundColor)
		if scrollView.backgroundColor != color { scrollView.backgroundColor = color }
		context.coordinator.refreshContentIfNeeded()
	}

	@MainActor
	public final class Coordinator: NSObject, NSTextViewDelegate {
		var parent: MarkdownInstantPreview
		private weak var scrollView: NSScrollView?
		private weak var textView: NSTextView?
		nonisolated(unsafe) private var boundsObserver: NSObjectProtocol?
		private var didReportReady = false
		private var didApplyInitialScroll = false
		private var renderedText: String?
		private var renderedTheme: MarkdownTheme?
		private var renderedFontSize: CGFloat?

		init(parent: MarkdownInstantPreview) { self.parent = parent }

		deinit {
			if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
		}

		func attach(scrollView: NSScrollView, textView: NSTextView) {
			self.scrollView = scrollView
			self.textView = textView
			renderedText = parent.text
			renderedTheme = parent.theme
			renderedFontSize = parent.fontSize
			boundsObserver = NotificationCenter.default.addObserver(
				forName: NSView.boundsDidChangeNotification,
				object: scrollView.contentView,
				queue: .main
			) { [weak self] _ in
				MainActor.assumeIsolated { self?.reportScrollFraction() }
			}
		}

		func refreshContentIfNeeded() {
			guard let textView else { return }
			guard renderedText != parent.text
				|| renderedTheme != parent.theme
				|| renderedFontSize != parent.fontSize else { return }
			renderedText = parent.text
			renderedTheme = parent.theme
			renderedFontSize = parent.fontSize
			textView.textStorage?.setAttributedString(InstantAttributedRenderer.render(
				parent.text, theme: parent.theme, fontSize: parent.fontSize))
		}

		func didAttach() {
			guard !didReportReady else { return }
			didReportReady = true
			applyInitialScrollIfNeeded()
			parent.onReady?()
			reportScrollFraction()
		}

		public func textViewDidChangeSelection(_ notification: Notification) {
			guard let textView else { return }
			parent.onSourceSelectionChanged?(
				Self.sourceRange(for: textView.selectedRange(), in: textView.textStorage))
		}

		private func applyInitialScrollIfNeeded() {
			guard !didApplyInitialScroll, let scrollView,
			      let initial = parent.initialScrollFraction else { return }
			didApplyInitialScroll = true
			let clip = scrollView.contentView
			let documentHeight = scrollView.documentView?.bounds.height ?? 0
			let maximum = max(0, documentHeight - clip.bounds.height)
			clip.scroll(to: NSPoint(x: 0, y: maximum * max(0, min(1, initial))))
			scrollView.reflectScrolledClipView(clip)
		}

		private func reportScrollFraction() {
			guard let scrollView else { return }
			let clip = scrollView.contentView
			let documentHeight = scrollView.documentView?.bounds.height ?? 0
			let maximum = max(0, documentHeight - clip.bounds.height)
			let fraction = maximum > 0 ? clip.bounds.minY / maximum : 0
			parent.onScrollFractionChanged?(Double(max(0, min(1, fraction))))
		}

		private static func sourceRange(
			for rendered: NSRange, in storage: NSTextStorage?
		) -> NSRange? {
			guard let storage, storage.length > 0 else { return nil }
			guard let start = sourceOffset(
				at: rendered.location, endAffinity: false, in: storage),
			      let end = sourceOffset(
					at: NSMaxRange(rendered), endAffinity: true, in: storage),
			      end >= start else { return nil }
			return NSRange(location: start, length: end - start)
		}

		private static func sourceOffset(
			at renderedOffset: Int,
			endAffinity: Bool,
			in storage: NSTextStorage
		) -> Int? {
			let index: Int
			if renderedOffset >= storage.length {
				index = storage.length - 1
			} else if endAffinity, renderedOffset > 0 {
				index = renderedOffset - 1
			} else {
				index = renderedOffset
			}
			var range = NSRange()
			guard let stamp = storage.attribute(
				.markdownSourceOffset, at: index, effectiveRange: &range) as? Int else { return nil }
			let delta = endAffinity
				? min(renderedOffset - range.location, range.length)
				: max(0, renderedOffset - range.location)
			return stamp + delta
		}
	}
}

private final class InstantPreviewTextView: NSTextView {
	var onAttached: (() -> Void)?

	override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		if window != nil { onAttached?() }
	}
}

@MainActor
private enum InstantAttributedRenderer {
	/// A heading-aware, syntax-light rendering path for the launch window. It
	/// deliberately avoids constructing a swift-markdown syntax tree: that full
	/// parse follows immediately in the persistent document, while this surface
	/// only has to be readable and selectable for the first launch frame.
	static func renderLaunch(
		_ markdown: String, theme: MarkdownTheme, fontSize: CGFloat
	) -> NSAttributedString {
		let output = NSMutableAttributedString()
		var insideFence = false
		for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
			var line = String(rawLine)
			if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
				insideFence.toggle()
				continue
			}

			let font: NSFont
			let color: NSColor
			let spacingBefore: CGFloat
			let spacingAfter: CGFloat
			if insideFence {
				font = .monospacedSystemFont(ofSize: fontSize * 0.9, weight: .regular)
				color = NSColor(theme.codeForeground)
				spacingBefore = 0
				spacingAfter = 0
			} else if let heading = launchHeading(in: line) {
				line = heading.text
				font = headingFont(heading.level, fontSize)
				color = NSColor(theme.headingColor)
				spacingBefore = heading.level <= 2 ? 18 : 10
				spacingAfter = heading.level <= 2 ? 8 : 4
			} else {
				line = launchBodyText(line)
				font = bodyFont(fontSize, theme)
				color = NSColor(theme.textColor)
				spacingBefore = 0
				spacingAfter = line.isEmpty ? 4 : 2
			}
			appendPlain(
				line, to: output, font: font, color: color,
				background: insideFence ? NSColor(theme.codeBackground) : nil)
			terminate(output, spacingBefore: spacingBefore, spacingAfter: spacingAfter)
		}
		return output
	}

	private static func launchHeading(in line: String) -> (level: Int, text: String)? {
		let hashes = line.prefix { $0 == "#" }.count
		guard (1...6).contains(hashes) else { return nil }
		let remainder = line.dropFirst(hashes)
		guard remainder.first == " " else { return nil }
		return (hashes, launchBodyText(String(remainder.dropFirst())))
	}

	private static func launchBodyText(_ source: String) -> String {
		var text = source
		let trimmed = text.drop(while: { $0 == " " || $0 == "\t" })
		if trimmed.hasPrefix("> ") {
			text = "▎ " + trimmed.dropFirst(2)
		} else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
			text = "• " + trimmed.dropFirst(2)
		}
		for marker in ["**", "__", "~~", "`"] {
			text = text.replacingOccurrences(of: marker, with: "")
		}
		return text
	}

	static func render(
		_ markdown: String, theme: MarkdownTheme, fontSize: CGFloat
	) -> NSAttributedString {
		let output = NSMutableAttributedString()
		for block in MarkdownBlockParser.parse(
			markdown, theme: theme, fontSize: fontSize, trackSourceOffsets: true) {
			append(block, to: output, theme: theme, fontSize: fontSize, depth: 0)
		}
		return output
	}

	private static func append(
		_ block: MarkdownBlock,
		to output: NSMutableAttributedString,
		theme: MarkdownTheme,
		fontSize: CGFloat,
		depth: Int
	) {
		switch block {
		case .heading(let level, let content, _):
			appendInline(content, to: output, font: headingFont(level, fontSize), color: NSColor(theme.headingColor), theme: theme)
			terminate(output, spacingBefore: level <= 2 ? 20 : 12, spacingAfter: level <= 2 ? 10 : 6)
		case .paragraph(let content, _, _):
			appendInline(content, to: output, font: bodyFont(fontSize, theme), color: NSColor(theme.textColor), theme: theme)
			terminate(output, spacingBefore: 0, spacingAfter: 10)
		case .blockquote(let children, _):
			for child in children { append(child, to: output, theme: theme, fontSize: fontSize, depth: depth + 1) }
		case .orderedList(let items, let start, _):
			appendList(items, ordered: true, start: start, to: output, theme: theme, fontSize: fontSize, depth: depth)
		case .unorderedList(let items, _):
			appendList(items, ordered: false, start: 1, to: output, theme: theme, fontSize: fontSize, depth: depth)
		case .codeBlock(let code, let language, _, _):
			appendPlain((language.map { "\($0)\n" } ?? "") + code, to: output, font: .monospacedSystemFont(ofSize: fontSize * 0.9, weight: .regular), color: NSColor(theme.codeForeground), background: NSColor(theme.codeBackground))
			terminate(output, spacingBefore: 10, spacingAfter: 12)
		case .table(let header, let rows, _, _):
			let allRows = [header] + rows
			for row in allRows {
				appendPlain(row.map(cellText).joined(separator: "   |   "), to: output, font: bodyFont(fontSize * 0.9, theme), color: NSColor(theme.textColor))
				terminate(output, spacingBefore: 0, spacingAfter: 3)
			}
		case .thematicBreak:
			appendPlain("────────", to: output, font: bodyFont(fontSize, theme), color: NSColor(theme.secondaryColor))
			terminate(output, spacingBefore: 10, spacingAfter: 10)
		case .image(_, let alt, _, _, _):
			appendPlaceholder("▧ \(alt)", to: output, theme: theme, fontSize: fontSize)
		case .imageRow(let images, _):
			appendPlaceholder(images.map(\.alt).joined(separator: "  ·  "), to: output, theme: theme, fontSize: fontSize)
		case .figure(_, let caption, _):
			appendPlaceholder("▧ \(caption)", to: output, theme: theme, fontSize: fontSize)
		case .htmlBlock(let content, _, _):
			appendPlaceholder(HTMLAttributeParser.stripTags(content), to: output, theme: theme, fontSize: fontSize)
		case .details(let summary, _, let children, _):
			appendPlaceholder("▸ \(summary)", to: output, theme: theme, fontSize: fontSize)
			for child in children { append(child, to: output, theme: theme, fontSize: fontSize, depth: depth + 1) }
		case .alert(let type, let children, _):
			appendPlaceholder(type.label, to: output, theme: theme, fontSize: fontSize)
			for child in children { append(child, to: output, theme: theme, fontSize: fontSize, depth: depth + 1) }
		case .frontmatter(let pairs, _):
			for pair in pairs { appendPlaceholder("\(pair.key): \(pair.value)", to: output, theme: theme, fontSize: fontSize) }
		case .aligned(_, let inner, _):
			append(inner, to: output, theme: theme, fontSize: fontSize, depth: depth)
		case .definitionList(let items, _):
			for item in items {
				appendPlain(item.term, to: output, font: bodyFont(fontSize, theme).applyingInlineTraits(.bold, family: theme.fontFamily), color: NSColor(theme.textColor))
				terminate(output, spacingBefore: 4, spacingAfter: 2)
				for definition in item.definitions { appendPlaceholder("  \(definition)", to: output, theme: theme, fontSize: fontSize) }
			}
		}
	}

	private static func appendList(
		_ items: [ListItemContent], ordered: Bool, start: Int,
		to output: NSMutableAttributedString, theme: MarkdownTheme,
		fontSize: CGFloat, depth: Int
	) {
		for (index, item) in items.enumerated() {
			let marker: String
			if let checkbox = item.checkbox {
				marker = checkbox == .checked ? "☑ " : "☐ "
			} else {
				marker = ordered ? "\(start + index). " : "• "
			}
			appendPlain(String(repeating: "  ", count: depth) + marker, to: output, font: bodyFont(fontSize, theme), color: NSColor(theme.secondaryColor))
			for child in item.blocks { append(child, to: output, theme: theme, fontSize: fontSize, depth: depth + 1) }
		}
	}

	private static func appendPlaceholder(
		_ text: String, to output: NSMutableAttributedString,
		theme: MarkdownTheme, fontSize: CGFloat
	) {
		appendPlain(text, to: output, font: bodyFont(fontSize, theme), color: NSColor(theme.secondaryColor))
		terminate(output, spacingBefore: 4, spacingAfter: 8)
	}

	private static func appendInline(
		_ inline: AttributedString, to output: NSMutableAttributedString,
		font: NSFont, color: NSColor, theme: MarkdownTheme
	) {
		for run in inline.runs {
			let substring = String(inline[run.range].characters)
			let traits = run.inlineFontTraits ?? []
			var attributes: [NSAttributedString.Key: Any] = [
				.font: font.applyingInlineTraits(traits, family: theme.fontFamily),
				.foregroundColor: color,
			]
			if let foreground = run.foregroundColor { attributes[.foregroundColor] = NSColor(foreground) }
			if let background = run.backgroundColor { attributes[.backgroundColor] = NSColor(background) }
			if let link = run.link { attributes[.link] = link }
			if run.underlineStyle != nil { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
			if run.strikethroughStyle != nil { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
			if let baseline = run.baselineOffset { attributes[.baselineOffset] = baseline }
			if let sourceOffset = run.markdownSourceOffset { attributes[.markdownSourceOffset] = sourceOffset }
			output.append(NSAttributedString(string: substring, attributes: attributes))
		}
	}

	private static func appendPlain(
		_ text: String, to output: NSMutableAttributedString,
		font: NSFont, color: NSColor, background: NSColor? = nil
	) {
		var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
		if let background { attributes[.backgroundColor] = background }
		output.append(NSAttributedString(string: text, attributes: attributes))
	}

	private static func terminate(
		_ output: NSMutableAttributedString,
		spacingBefore: CGFloat,
		spacingAfter: CGFloat
	) {
		let paragraphStart: Int
		if output.length > 0 {
			let previousBreak = (output.string as NSString).range(
				of: "\n", options: .backwards,
				range: NSRange(location: 0, length: output.length))
			paragraphStart = previousBreak.location == NSNotFound
				? 0 : NSMaxRange(previousBreak)
		} else {
			paragraphStart = 0
		}
		output.append(NSAttributedString(string: "\n"))
		let style = NSMutableParagraphStyle()
		style.lineHeightMultiple = 1.35
		style.paragraphSpacingBefore = spacingBefore
		style.paragraphSpacing = spacingAfter
		output.addAttribute(
			.paragraphStyle, value: style,
			range: NSRange(
				location: paragraphStart,
				length: output.length - paragraphStart))
	}

	private static func bodyFont(_ size: CGFloat, _ theme: MarkdownTheme) -> NSFont {
		let base = NSFont.systemFont(ofSize: size)
		guard theme.fontFamily != .system,
		      let descriptor = base.fontDescriptor.withDesign(theme.fontFamily.systemDesign),
		      let designed = NSFont(descriptor: descriptor, size: size) else { return base }
		return designed
	}

	private static func headingFont(_ level: Int, _ base: CGFloat) -> NSFont {
		let scales: [CGFloat] = [2, 1.5, 1.25, 1.1, 1, 0.875]
		return .systemFont(
			ofSize: base * scales[min(max(level - 1, 0), scales.count - 1)],
			weight: level <= 2 ? .bold : .semibold)
	}

	private static func cellText(_ cell: TableCell) -> String {
		switch cell {
		case .text(let attributed, _): String(attributed.characters)
		case .image(_, let alt, _, _, _): "▧ \(alt)"
		}
	}
}

extension NSAttributedString.Key {
	public static let markdownSourceOffset = NSAttributedString.Key("markdownSourceOffset")
}

private extension NSFont {
	func applyingInlineTraits(
		_ traits: InlineFontTraits,
		family: MarkdownFontFamily
	) -> NSFont {
		guard !traits.isEmpty else { return self }
		let weight: NSFont.Weight = traits.contains(.bold) ? .bold : .regular
		var result = traits.contains(.monospaced)
			? NSFont.monospacedSystemFont(ofSize: pointSize, weight: weight)
			: NSFont.systemFont(ofSize: pointSize, weight: weight)
		if !traits.contains(.monospaced), family != .system,
		   let descriptor = result.fontDescriptor.withDesign(family.systemDesign),
		   let designed = NSFont(descriptor: descriptor, size: pointSize) {
			result = designed
		}
		if traits.contains(.italic),
		   let italic = NSFont(
				descriptor: result.fontDescriptor.withSymbolicTraits(.italic),
				size: pointSize) {
			result = italic
		}
		return result
	}
}
#endif
