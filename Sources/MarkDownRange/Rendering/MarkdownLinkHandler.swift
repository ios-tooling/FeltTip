//
//  MarkdownLinkHandler.swift
//  MarkDownRange
//
//  How the host opens a link the rendered page asked to follow, and how it
//  grants sandbox access to a local file the app can't read yet.
//
//  The renderer used to reach straight for `NSDocumentController`,
//  `NSWorkspace`, and `NSOpenPanel`. That both hard-wired it to AppKit and put
//  app-level policy — which documents open in-app, whether a link leaves the
//  app, what the grant prompt says — inside the framework. The host owns that
//  decision now; the platform defaults preserve the previous behavior for
//  hosts that don't supply one.
//

import SwiftUI

@MainActor public protocol MarkdownLinkHandler: AnyObject, Sendable {
	/// Open `url`. `isMarkdownDocument` is true when the target is a local
	/// markdown file, which a host may want to open in-app rather than hand to
	/// the system.
	func openLink(_ url: URL, isMarkdownDocument: Bool)

	/// The sandbox refused `url`. Ask for access at `scope` and open it if
	/// granted. Returns any security-scoped URL the caller started accessing,
	/// so the renderer can release it when the page goes away — returning nil
	/// means nothing was granted and nothing needs releasing.
	func requestAccess(to url: URL, scope: MarkdownLinkAccessScope) -> URL?
}

/// Nil rather than the shared default: an `EnvironmentKey`'s default value is
/// evaluated in a nonisolated context, and the handlers are main-actor types.
/// Callers resolve the fallback where they use it, on the main actor.
private struct MarkdownLinkHandlerKey: EnvironmentKey {
	static let defaultValue: (any MarkdownLinkHandler)? = nil
}

public extension EnvironmentValues {
	var markdownLinkHandler: (any MarkdownLinkHandler)? {
		get { self[MarkdownLinkHandlerKey.self] }
		set { self[MarkdownLinkHandlerKey.self] = newValue }
	}
}

public extension View {
	/// Route link opening and sandbox-access grants from any rendered markdown
	/// in this subtree through `handler`.
	func markdownLinkHandler(_ handler: any MarkdownLinkHandler) -> some View {
		environment(\.markdownLinkHandler, handler)
	}
}
