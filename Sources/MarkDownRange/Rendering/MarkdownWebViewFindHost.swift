//
//  MarkdownWebViewFindHost.swift
//  MarkDownRange
//
//  Hosts a `MarkdownWebView`'s WKWebView together with a find bar driven by
//  WKWebView's own `find(_:configuration:)` — which highlights the match and
//  scrolls it into view itself. (WKWebView nominally conforms to
//  NSTextFinderClient, but its implementation neither responds to
//  `performTextFinderAction:` nor reveals matches, so the standard
//  NSTextFinder path is a dead end.) Hosts route ⌘F here exactly like they
//  route it at an NSTextView.
//

#if os(macOS)
	import AppKit
	import WebKit

public final class MarkdownWebViewFindHost: NSView, NSSearchFieldDelegate {
	public let webView: WKWebView
	private let bar = NSVisualEffectView()
	private let searchField = NSSearchField()
	private var barVisible = false
	private let barHeight: CGFloat = 34

	public init(webView: WKWebView) {
		self.webView = webView
		super.init(frame: .zero)
		addSubview(webView)
		buildBar()
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	// MARK: Formatting key equivalents

	public override func performKeyEquivalent(with event: NSEvent) -> Bool {
		// Bare WKWebView doesn't map ⌘B/⌘I/⌘⇧X to editing commands without
		// a menu; claim them when the web view is focused and drive WebKit's
		// editor commands, which reach the source through the edit bridge's
		// formatBold/formatItalic/formatStrikeThrough path.
		let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
		guard webViewIsFocused else { return super.performKeyEquivalent(with: event) }
		switch (event.charactersIgnoringModifiers?.lowercased() ?? "", mods) {
		case ("b", [.command]):
			toggleBold()
			return true
		case ("i", [.command]):
			toggleItalic()
			return true
		case ("x", [.command, .shift]):
			toggleStrikethrough()
			return true
		default:
			return super.performKeyEquivalent(with: event)
		}
	}

	/// Menu-item entry points: drive WebKit's editor commands, which reach
	/// the markdown source through the edit bridge's format-command path.
	public func toggleBold() {
		webView.evaluateJavaScript("document.execCommand('bold')", completionHandler: nil)
	}

	public func toggleItalic() {
		webView.evaluateJavaScript("document.execCommand('italic')", completionHandler: nil)
	}

	public func toggleStrikethrough() {
		webView.evaluateJavaScript("document.execCommand('strikeThrough')", completionHandler: nil)
	}

	private var webViewIsFocused: Bool {
		guard let responder = window?.firstResponder as? NSView else { return false }
		return responder === webView || responder.isDescendant(of: webView)
	}

	// MARK: Find actions (routed from the app's Find menu, NSTextView-style)

	public override func performTextFinderAction(_ sender: Any?) {
		guard let item = sender as? NSValidatedUserInterfaceItem,
			  let action = NSTextFinder.Action(rawValue: item.tag) else { return }
		switch action {
		case .showFindInterface, .showReplaceInterface:
			showBar()
		case .nextMatch:
			find(forward: true)
		case .previousMatch:
			find(forward: false)
		case .setSearchString:
			webView.evaluateJavaScript("window.getSelection().toString()") { [weak self] result, _ in
				if let text = result as? String, !text.isEmpty { self?.searchField.stringValue = text }
			}
		case .hideFindInterface:
			hideBar()
		default:
			break
		}
	}

	private func showBar() {
		barVisible = true
		bar.isHidden = false
		needsLayout = true
		window?.makeFirstResponder(searchField)
	}

	private func hideBar() {
		barVisible = false
		bar.isHidden = true
		needsLayout = true
		window?.makeFirstResponder(webView)
		// Drop the match highlight (find() selects the match).
		webView.evaluateJavaScript("window.getSelection().removeAllRanges()", completionHandler: nil)
	}

	private func find(forward: Bool) {
		let term = searchField.stringValue
		guard !term.isEmpty else { return }
		let configuration = WKFindConfiguration()
		configuration.backwards = !forward
		configuration.caseSensitive = false
		configuration.wraps = true
		webView.find(term, configuration: configuration) { result in
			if !result.matchFound { NSSound.beep() }
		}
	}

	// MARK: Bar UI

	private func buildBar() {
		bar.material = .headerView
		bar.blendingMode = .withinWindow
		bar.isHidden = true

		searchField.placeholderString = "Find in document"
		searchField.delegate = self
		searchField.target = self
		searchField.action = #selector(searchFieldAction(_:))
		searchField.sendsSearchStringImmediately = false
		searchField.sendsWholeSearchString = true

		let previous = chevronButton(system: "chevron.up", action: #selector(findPrevious))
		let next = chevronButton(system: "chevron.down", action: #selector(findNext))
		let done = NSButton(title: "Done", target: self, action: #selector(dismissBar))
		done.bezelStyle = .accessoryBarAction
		done.controlSize = .small

		let stack = NSStackView(views: [searchField, previous, next, done])
		stack.orientation = .horizontal
		stack.spacing = 6
		stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
		stack.translatesAutoresizingMaskIntoConstraints = false
		bar.addSubview(stack)
		addSubview(bar)
		NSLayoutConstraint.activate([
			stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
			stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
			stack.topAnchor.constraint(equalTo: bar.topAnchor),
			stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
			searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 320)
		])
	}

	private func chevronButton(system name: String, action: Selector) -> NSButton {
		let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
		let button = NSButton(image: image, target: self, action: action)
		button.bezelStyle = .accessoryBarAction
		button.controlSize = .small
		return button
	}

	@objc private func searchFieldAction(_ sender: NSSearchField) {
		guard !sender.stringValue.isEmpty else { return }
		let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
		find(forward: !backwards)
	}

	@objc private func findNext() { find(forward: true) }
	@objc private func findPrevious() { find(forward: false) }
	@objc private func dismissBar() { hideBar() }

	public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
		if selector == #selector(NSResponder.cancelOperation(_:)) {
			hideBar()
			return true
		}
		return false
	}

	// MARK: Layout

	public override func layout() {
		super.layout()
		let height = barVisible ? barHeight : 0
		bar.frame = NSRect(x: 0, y: bounds.height - height, width: bounds.width, height: barHeight)
		webView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - height)
	}

	public override func resizeSubviews(withOldSize oldSize: NSSize) {
		super.resizeSubviews(withOldSize: oldSize)
		needsLayout = true
	}
}
#endif
