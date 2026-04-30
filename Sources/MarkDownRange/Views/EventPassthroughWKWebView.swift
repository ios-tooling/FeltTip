//
//  EventPassthroughWKWebView.swift
//  MarkDownRange
//

#if os(macOS)
import WebKit

/// `WKWebView` that does not claim pointer/scroll events, so enclosing SwiftUI
/// containers keep hover, click, and wheel behavior.
final class EventPassthroughWKWebView: WKWebView {
	override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif
