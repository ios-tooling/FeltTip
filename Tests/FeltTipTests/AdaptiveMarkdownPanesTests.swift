#if os(iOS)
import Observation
import SwiftUI
import Testing
import UIKit
import WebKit
@testable import FeltTip

@Suite(.serialized) @MainActor
struct AdaptiveMarkdownPanesTests {
	@Test func sourceReportsCollapsedCaretAndCanRevisitDrivenPosition() throws {
		var exact: NSRange?
		var mirror: NSRange?
		var reported: [Double] = []
		let editor = MarkdownUITextEditor(
			text: .constant("Alpha beta"), fontSize: 14,
			onScrollFractionChanged: { reported.append($0) },
			scrollTarget: MarkdownScrollTarget(topFraction: 0.5, token: 1),
			onSelectionChanged: { mirror = $0 },
			onSourceSelectionChanged: { exact = $0 })
		let coordinator = editor.makeCoordinator()
		let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
		textView.text = "Alpha beta"
		textView.selectedRange = NSRange(location: 6, length: 0)
		coordinator.textViewDidChangeSelection(textView)
		#expect(exact == NSRange(location: 6, length: 0))
		#expect(mirror == nil)

		textView.contentSize = CGSize(width: 300, height: 1200)
		coordinator.applyScrollTarget(to: textView)
		coordinator.scrollViewDidScroll(textView)
		#expect(reported.isEmpty)
		textView.contentOffset.y = 600
		coordinator.scrollViewDidScroll(textView)
		textView.contentOffset.y = 500
		coordinator.scrollViewDidScroll(textView)
		#expect(reported == [0.6, 0.5])
	}

	@Test func scrollTargetWaitsForViewportGeometry() {
		let editor = MarkdownUITextEditor(text: .constant("Text"), fontSize: 14,
			scrollTarget: MarkdownScrollTarget(topFraction: 0.75, token: 1))
		let coordinator = editor.makeCoordinator()
		let textView = UITextView(frame: .zero)
		coordinator.applyScrollTarget(to: textView)
		textView.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
		textView.contentSize = CGSize(width: 300, height: 1200)
		coordinator.applyScrollTarget(to: textView)
		#expect(textView.contentOffset.y == 750)
	}

	@Test func regularPanesSyncBothWaysRestoreFreshTokensAndReportSelection() async throws {
		let model = PaneModel()
		let host = UIHostingController(rootView: PaneHost(model: model))
		let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
		window.rootViewController = host
		window.makeKeyAndVisible()
		defer { window.isHidden = true }
		host.view.layoutIfNeeded()
		try await waitUntil {
			find(UITextView.self, in: host.view) != nil && find(WKWebView.self, in: host.view) != nil
		}
		let raw = try #require(find(UITextView.self, in: host.view))
		let web = try #require(find(WKWebView.self, in: host.view))
		try await waitUntil {
			let ready = try? await evaluate("String(typeof window.__mdScrollToFraction === 'function')", in: web)
			return ready == "true" && abs(rawFraction(raw) - 0.6) < 0.04
		}
		try await waitUntil { abs(try await webFraction(web) - 0.6) < 0.04 }

		// Real page scroll reporting must update persistence and the raw pane.
		_ = try await evaluate("window.scrollTo(0, (document.documentElement.scrollHeight - innerHeight) * 0.35)", in: web)
		try await waitUntil {
			abs((model.savedFraction ?? -1) - 0.35) < 0.04 && abs(rawFraction(raw) - 0.35) < 0.04
		}
		raw.setContentOffset(CGPoint(x: 0, y: (raw.contentSize.height - raw.bounds.height) * 0.75), animated: false)
		try await waitUntil { abs(try await webFraction(web) - 0.75) < 0.04 }

		// Same host fraction with a fresh token must restore both retained panes.
		for token in [2, 3] {
			model.target = MarkdownScrollTarget(topFraction: 0.6, token: token)
			try await waitUntil {
				let rendered = try await webFraction(web)
				return abs(rawFraction(raw) - 0.6) < 0.04 && abs(rendered - 0.6) < 0.04
			}
			_ = try await evaluate("window.scrollTo(0, (document.documentElement.scrollHeight - innerHeight) * 0.3)", in: web)
			try await waitUntil { abs(rawFraction(raw) - 0.3) < 0.04 }
		}

		_ = try await evaluate("document.hasFocus = function () { return true }; window.__mdPlaceCaret(5, 3); document.dispatchEvent(new Event('selectionchange'))", in: web)
		try await waitUntil { model.selection == NSRange(location: 5, length: 3) }
	}

	@Test func compactPaneSwitchKeepsTheReadersPosition() async throws {
		let model = PaneModel()
		let host = UIHostingController(rootView: PaneHost(model: model, sizeClass: .compact))
		let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 800))
		window.rootViewController = host
		window.makeKeyAndVisible()
		defer { window.isHidden = true }
		host.view.layoutIfNeeded()
		try await waitUntil { find(WKWebView.self, in: host.view) != nil }
		let firstWeb = try #require(find(WKWebView.self, in: host.view))
		try await waitUntil { abs(try await webFraction(firstWeb) - 0.6) < 0.04 }
		_ = try await evaluate("window.scrollTo(0, (document.documentElement.scrollHeight - innerHeight) * 0.4)", in: firstWeb)
		try await waitUntil { abs((model.savedFraction ?? -1) - 0.4) < 0.04 }
		let picker = try #require(find(UISegmentedControl.self, in: host.view))
		chooseSegment(1, in: picker)
		try await waitUntil { find(UITextView.self, in: host.view) != nil }
		let raw = try #require(find(UITextView.self, in: host.view))
		try await waitUntil { abs(rawFraction(raw) - 0.4) < 0.04 }
		raw.setContentOffset(CGPoint(x: 0, y: (raw.contentSize.height - raw.bounds.height) * 0.7), animated: false)
		try await waitUntil { abs((model.savedFraction ?? -1) - 0.7) < 0.04 }
		chooseSegment(0, in: picker)
		try await waitUntil { find(WKWebView.self, in: host.view) != nil }
		let secondWeb = try #require(find(WKWebView.self, in: host.view))
		try await waitUntil { abs(try await webFraction(secondWeb) - 0.7) < 0.04 }
	}

	private func chooseSegment(_ index: Int, in picker: UISegmentedControl) {
		picker.selectedSegmentIndex = index
		// Package tests have no UIApplication to dispatch sendActions through.
		// Invoke the registered control action directly, preserving the actual
		// SwiftUI picker binding and pane transition.
		for target in picker.allTargets {
			for action in picker.actions(forTarget: target, forControlEvent: .valueChanged) ?? [] {
				_ = (target as? NSObject)?.perform(NSSelectorFromString(action), with: picker)
			}
		}
	}

	private func waitUntil(_ predicate: () async throws -> Bool) async throws {
		for _ in 0..<200 {
			if try await predicate() { return }
			try await Task.sleep(for: .milliseconds(25))
		}
		#expect(try await predicate(), "Timed out waiting for pane state")
	}

	private func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
		if let match = view as? T { return match }
		for child in view.subviews {
			if let match = find(type, in: child) { return match }
		}
		return nil
	}

	private func rawFraction(_ view: UITextView) -> Double {
		Double(view.contentOffset.y / max(1, view.contentSize.height - view.bounds.height))
	}

	private func evaluate(_ script: String, in view: WKWebView) async throws -> String? {
		try await BoundedTestCallbackWaiter.wait { completion in
			view.evaluateJavaScript(script) { result, error in
				if let error { completion(.failure(error)) }
				else { completion(.success(result as? String)) }
			}
		}
	}

	private func webFraction(_ view: WKWebView) async throws -> Double {
		let result = try await evaluate("String(window.scrollY / Math.max(1, document.documentElement.scrollHeight - innerHeight))", in: view)
		return Double(result ?? "") ?? -1
	}
}

@MainActor @Observable
private final class PaneModel {
	var text = (0..<200).map { "Line \($0) contains enough text for a scrolling document." }.joined(separator: "\n\n")
	var heading: String?
	var target = MarkdownScrollTarget(topFraction: 0.6, token: 1)
	var savedFraction: Double?
	var selection: NSRange?
}

private struct PaneHost: View {
	@Bindable var model: PaneModel
	var sizeClass: UserInterfaceSizeClass = .regular

	var body: some View {
		WebSplitMarkdownScreen(text: $model.text, selectedHeadingID: $model.heading,
			theme: .default, fontSize: 14, editablePreview: true,
			onSourceSelectionChanged: { model.selection = $0 },
			scrollTarget: model.target,
			onScrollFractionChanged: { model.savedFraction = $0 })
		.environment(\.horizontalSizeClass, sizeClass)
	}
}
#endif
