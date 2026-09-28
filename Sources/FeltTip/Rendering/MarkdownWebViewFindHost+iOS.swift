//
//  MarkdownWebViewFindHost+iOS.swift
//  FeltTip
//
//  iOS counterpart to the AppKit find host. macOS hand-builds a find bar
//  because WKWebView neither responds to `NSTextFinderClient` nor drives an
//  `NSTextFinder` — a dead end documented in MarkdownWebViewFindHost. iOS has
//  no such problem: WKWebView's own find interaction *is* the system find bar,
//  with match counts, next/previous, and Dictation. So this host is only the
//  container that owns the web view and forwards find requests to it.
//

#if os(iOS)
import UIKit
import WebKit

public final class MarkdownWebViewFindHost: UIView {
	public let webView: WKWebView
	public var isInactive = false {
		didSet {
			if isInactive { webView.endEditing(true) }
		}
	}

	public init(webView: WKWebView) {
		self.webView = webView
		super.init(frame: .zero)
		webView.isFindInteractionEnabled = true
		addSubview(webView)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

	public override func layoutSubviews() {
		super.layoutSubviews()
		webView.frame = bounds
	}

	/// Show the system find bar. Hosts route their Find affordance — a toolbar
	/// button, or ⌘F from a hardware keyboard — here.
	public func presentFind() {
		webView.findInteraction?.presentFindNavigator(showingReplace: false)
	}

	public func dismissFind() {
		webView.findInteraction?.dismissFindNavigator()
	}
}
#endif
