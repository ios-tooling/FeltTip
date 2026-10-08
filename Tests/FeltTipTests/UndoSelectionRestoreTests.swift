#if os(macOS)
import AppKit
import Observation
import SwiftUI
import Testing
import WebKit
@testable import FeltTip

@Suite(.serialized) @MainActor
struct UndoSelectionRestoreTests {
	@Test(arguments: ["raw", "styled", "splitRaw", "splitStyled"], ["s", "😀", "selected 😀 words"])
	func replacementUndoReselectsText(pane: String, selectedText: String) async throws {
		await CoordinatorBridgeHarness.pageSlots.acquire()
		defer { CoordinatorBridgeHarness.pageSlots.release() }
		let original = (0..<60).map { "Paragraph \($0) with some ordinary text." }.joined(separator: "\n\n")
			+ "\n\nBefore \(selectedText) after\n\n"
			+ (60..<120).map { "Paragraph \($0) with some ordinary text." }.joined(separator: "\n\n")
		let selected = NSRange(location: (original as NSString).range(of: "Before ").location + 7,
			length: (selectedText as NSString).length)
		let model = UndoSelectionModel(text: original)
		let host = NSHostingView(rootView: UndoSelectionHost(model: model, pane: pane))
		host.frame = NSRect(x: 0, y: 0, width: 900, height: 450)
		let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
		window.animationBehavior = .none
		window.isReleasedWhenClosed = false
		defer { window.contentView = nil; window.close() }
		window.contentView = host
		window.orderFront(nil)
		host.layoutSubtreeIfNeeded()
		let usesRaw = pane == "raw" || pane == "splitRaw"
		for _ in 0..<200 {
			host.layoutSubtreeIfNeeded()
			if usesRaw, descendant(NSTextView.self, in: host) != nil { break }
			if !usesRaw, let web = descendant(WKWebView.self, in: host),
			   (try? await web.evaluateJavaScript("typeof window.__mdPlaceCaret")) as? String == "function" { break }
			try await Task.sleep(for: .milliseconds(25))
		}
		let raw = descendant(NSTextView.self, in: host)
		let web = descendant(WKWebView.self, in: host)
		if usesRaw {
			let raw = try #require(raw)
			window.makeFirstResponder(raw)
			raw.setSelectedRange(selected)
			raw.scrollRangeToVisible(selected)
			raw.insertText("x", replacementRange: selected)
		} else {
			let web = try #require(web)
			window.makeFirstResponder(web)
			_ = try await web.evaluateJavaScript("window.__mdPlaceCaret(\(selected.location), \(selected.length)); document.execCommand('insertText', false, 'x');")
		}
		let edited = (original as NSString).replacingCharacters(in: selected, with: "x")
		for _ in 0..<200 where model.text != edited { try await Task.sleep(for: .milliseconds(25)) }
		#expect(model.text == edited)
		#expect(model.selectionAtEdit == selected)
		// Keep the selected line away from the center to detect handoff centering.
		try await Task.sleep(for: .milliseconds(200))
		if usesRaw, let clip = raw?.enclosingScrollView?.contentView {
			clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + 80))
		} else if let web {
			_ = try await web.evaluateJavaScript("window.scrollBy(0, 80)")
		}
		try await Task.sleep(for: .milliseconds(200))
		for token in 1...3 {
			let rawScrollBefore = raw?.enclosingScrollView?.contentView.bounds.minY
			let webScrollBefore = try await web?.evaluateJavaScript("window.scrollY") as? Double
			let undo = token != 2
			let range = undo ? selected : NSRange(location: selected.location + 1, length: 0)
			model.text = undo ? original : edited
			model.caret = MarkdownCaretTarget(offset: range.location, token: token, selectionLength: range.length, preservesScrollPosition: true)
			// The app also renews its mode-handoff target on undo/redo.
			model.selection = MarkdownSelectionTarget(range: range, token: token, preservesScrollPosition: true)
			for _ in 0..<200 {
				host.layoutSubtreeIfNeeded()
				if usesRaw, raw?.selectedRange() == range, raw?.string == model.text { break }
				if !usesRaw, let web,
				   (try? await web.evaluateJavaScript("window.getSelection().toString()")) as? String == (undo ? selectedText : "") { break }
				try await Task.sleep(for: .milliseconds(25))
			}
			try await Task.sleep(for: .milliseconds(150))
			if let rawScrollBefore, let raw {
				#expect(abs(raw.enclosingScrollView!.contentView.bounds.minY - rawScrollBefore) < 2)
			}
			if let webScrollBefore, let web {
				let after = try #require(try await web.evaluateJavaScript("window.scrollY") as? Double)
				#expect(abs(after - webScrollBefore) < 2)
			}
			if usesRaw {
				#expect(raw?.selectedRange() == range)
				#expect(window.firstResponder === raw)
			} else {
				let web = try #require(web)
				#expect(try await web.evaluateJavaScript("window.getSelection().toString()") as? String == (undo ? selectedText : ""))
				try await assertStamps(in: web, source: model.text)
				let responder = window.firstResponder as? NSView
				#expect(responder === web || responder?.isDescendant(of: web) == true)
			}
		}
	}

	private func assertStamps(in web: WKWebView, source: String) async throws {
		let value = try await web.evaluateJavaScript("Array.from(document.querySelectorAll('[data-s]:not([data-md-inline-caret-home])')).map(e => ({start: Number(e.dataset.s), text: e.textContent}))")
		let runs = try #require(value as? [[String: Any]])
		#expect(!runs.isEmpty)
		let ns = source as NSString
		for run in runs {
			let start = try #require(run["start"] as? Int)
			let text = try #require(run["text"] as? String).replacingOccurrences(of: "\u{00A0}", with: " ")
			let count = (text as NSString).length
			guard start >= 0, start + count <= ns.length else {
				Issue.record("Rendered run is outside the restored source")
				continue
			}
			#expect(ns.substring(with: NSRange(location: start, length: count)) == text)
		}
	}

	private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
		if let match = view as? T { return match }
		return view.subviews.lazy.compactMap { descendant(type, in: $0) }.first
	}
}

@MainActor @Observable private final class UndoSelectionModel {
	var text: String
	var reportedSelection: NSRange?
	var selectionAtEdit: NSRange?
	func edit(_ text: String, caret: Int?) {
		selectionAtEdit = reportedSelection
		self.text = text
	}
	var caret: MarkdownCaretTarget?
	var selection: MarkdownSelectionTarget?
	init(text: String) { self.text = text }
}

private struct UndoSelectionHost: View {
	@Bindable var model: UndoSelectionModel
	let pane: String
	@State private var heading: String?
	var body: some View {
		switch pane {
		case "raw":
			RawMarkdownScreen(text: $model.text, selectedHeadingID: $heading, fontSize: 14,
				onSourceEdit: { model.edit($0, caret: $1) },
				onSourceSelectionChanged: { model.reportedSelection = $0 },
				caretTarget: model.caret, selectionTarget: model.selection)
		case "styled":
			MarkdownWebView(text: model.text, theme: .default, fontSize: 14)
				.editable(true).onSourceEdit { model.edit($0, caret: $1) }
				.onSourceSelectionChanged { model.reportedSelection = $0 }
				.caretTarget(model.caret).selectionTarget(model.selection)
		default:
			WebSplitMarkdownScreen(text: $model.text, selectedHeadingID: $heading, theme: .default,
				fontSize: 14, editablePreview: true,
				onSourceEdit: { model.edit($0, caret: $1) },
				onSourceSelectionChanged: { model.reportedSelection = $0 },
				selectionTargetPane: pane == "splitRaw" ? .rendered : .source,
				caretTarget: model.caret, selectionTarget: model.selection)
		}
	}
}
#endif
