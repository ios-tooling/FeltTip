#if os(macOS)
#if os(macOS)
	import AppKit
#else
	import UIKit
#endif
import Testing
import WebKit
@testable import FeltTip

@MainActor
@Suite(.serialized)
struct MarkdownWebViewFindHostTests {
	@Test
	func findFieldSearchesAsItsQueryChanges() throws {
		let webView = WKWebView()
		let host = MarkdownWebViewFindHost(webView: webView)

		let item = NSMenuItem()
		item.tag = NSTextFinder.Action.showFindInterface.rawValue
		host.performTextFinderAction(item)

		let searchField = try #require(findSearchField(in: host))
		#expect(searchField.sendsSearchStringImmediately)
		#expect(!searchField.sendsWholeSearchString)
	}

	@Test
	func findActionsNavigateNumericTableMatchesWithoutMutatingTheDocument() async throws {
		let webView = WKWebView()
		let host = MarkdownWebViewFindHost(webView: webView)
		host.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
		let window = NSWindow(
			contentRect: host.frame,
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.contentView = host
		window.orderFront(nil)

		let markdown = """
		| Run | Duration |
		| --- | --- |
		| first | 83.632438016s |
		| second | 83.999s |
		"""
		webView.loadHTMLString(
			MarkdownHTMLRenderer.renderDocument(markdown: markdown),
			baseURL: nil
		)
		try await waitUntilLoaded(webView)
		let originalText = try await bodyText(in: webView)

		perform(.showFindInterface, on: host)
		let searchField = try #require(findSearchField(in: host))
		try await waitUntil("find field focus") { searchField.currentEditor() != nil }
		searchField.stringValue = "83"
		searchField.sendAction(searchField.action, to: searchField.target)

		try await waitUntil("first styled numeric match") {
			try await selectedRowText(in: webView)?.contains("first") == true
		}
		perform(.nextMatch, on: host)
		try await waitUntil("next styled numeric match") {
			try await selectedRowText(in: webView)?.contains("second") == true
		}
		perform(.previousMatch, on: host)
		try await waitUntil("previous styled numeric match") {
			try await selectedRowText(in: webView)?.contains("first") == true
		}

		searchField.stringValue = ""
		searchField.sendAction(searchField.action, to: searchField.target)
		try await waitUntil("cleared styled search selection") {
			try await webView.evaluateJavaScript("window.getSelection().isCollapsed") as? Bool == true
		}
		#expect(try await bodyText(in: webView) == originalText)
	}

	@Test
	func commandReturnInvokesStyledListInsertion() throws {
		let webView = ScriptRecordingWebView()
		let host = MarkdownWebViewFindHost(webView: webView)
		host.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
		let window = NSWindow(
			contentRect: host.frame,
			styleMask: [.borderless],
			backing: .buffered,
			defer: false)
		window.contentView = host
		window.orderFront(nil)
		window.makeFirstResponder(webView)
		webView.scripts.removeAll()
		let event = try #require(NSEvent.keyEvent(
			with: .keyDown,
			location: .zero,
			modifierFlags: .command,
			timestamp: 0,
			windowNumber: window.windowNumber,
			context: nil,
			characters: "\r",
			charactersIgnoringModifiers: "\r",
			isARepeat: false,
			keyCode: 36))

		#expect(host.performKeyEquivalent(with: event))
		#expect(webView.scripts.last?.contains(
			"__mdInsertListItem") == true)
	}

	@Test
	func inactivePrewarmedHostCannotTakeFocusFromTheVisibleEditor() throws {
		let root = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
		let visibleEditor = NSTextView(frame: root.bounds)
		let host = MarkdownWebViewFindHost(webView: WKWebView())
		host.frame = root.bounds
		root.addSubview(host)
		root.addSubview(visibleEditor)
		let window = NSWindow(
			contentRect: root.frame,
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.contentView = root
		window.orderFront(nil)
		try #require(window.makeFirstResponder(visibleEditor))

		try #require(window.makeFirstResponder(host))
		host.isInactive = true
		#expect(!host.acceptsFirstResponder)
		#expect(window.firstResponder !== host)
		let bold = try #require(NSEvent.keyEvent(
			with: .keyDown,
			location: .zero,
			modifierFlags: .command,
			timestamp: 0,
			windowNumber: window.windowNumber,
			context: nil,
			characters: "b",
			charactersIgnoringModifiers: "b",
			isARepeat: false,
			keyCode: 11
		))
		#expect(host.performKeyEquivalent(with: bold) == false)
	}

	@Test
	func dismissingFindRestoresTheEditableCaret() async throws {
		let harness = try await CoordinatorBridgeHarness(source: "Aster tail.\n")
		let host = harness.installFindHost()
		try await harness.placeCaret(11) // After the period.
		perform(.showFindInterface, on: host)
		let searchField = try #require(findSearchField(in: host))
		try await waitUntil("find field focus") { searchField.currentEditor() != nil }
		searchField.stringValue = "Aster"
		searchField.sendAction(searchField.action, to: searchField.target)
		try await waitUntil("styled find selection") {
			try await harness.webView.evaluateJavaScript("window.getSelection().toString()") as? String == "Aster"
		}

		perform(.hideFindInterface, on: host)
		try await waitUntil("restored caret") {
			let selection = try await harness.webView.evaluateJavaScript("window.getSelection().toString()") as? String
			return selection == ""
		}
		try await harness.type("!")
		#expect(harness.source == "Aster tail.!\n")
	}

	private func perform(
		_ action: NSTextFinder.Action,
		on host: MarkdownWebViewFindHost
	) {
		let item = NSMenuItem()
		item.tag = action.rawValue
		host.performTextFinderAction(item)
	}

	private func findSearchField(in view: NSView) -> NSSearchField? {
		if let searchField = view as? NSSearchField {
			return searchField
		}
		return view.subviews.lazy.compactMap(findSearchField(in:)).first
	}

	private func waitUntilLoaded(_ webView: WKWebView) async throws {
		try await waitUntil("rendered document load") {
			guard !webView.isLoading else {
				return false
			}
			return try await webView.evaluateJavaScript("document.readyState") as? String == "complete"
		}
	}

	private func bodyText(in webView: WKWebView) async throws -> String {
		try #require(
			try await webView.evaluateJavaScript("document.body.innerText") as? String
		)
	}

	private func selectedRowText(in webView: WKWebView) async throws -> String? {
		try await webView.evaluateJavaScript("""
			(function () {
			  var selection = window.getSelection()
			  if (!selection || !selection.rangeCount || selection.isCollapsed) return null
			  var node = selection.anchorNode
			  var element = node && (node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement)
			  var row = element && element.closest('tr')
			  return row ? row.innerText : null
			})()
			""") as? String
	}

	private func waitUntil(
		_ description: String,
		condition: () async throws -> Bool
	) async throws {
		for _ in 0..<150 {
			if try await condition() {
				return
			}
			try await Task.sleep(for: .milliseconds(10))
		}
		Issue.record("Timed out waiting for \(description)")
	}

	private final class ScriptRecordingWebView: WKWebView {
		var scripts: [String] = []

		override func evaluateJavaScript(
			_ javaScriptString: String,
			completionHandler: (@MainActor @Sendable (Any?, (any Error)?) -> Void)? = nil
		) {
			scripts.append(javaScriptString)
			completionHandler?(nil, nil)
		}
	}
}
#endif
