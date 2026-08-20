//
//  MarkdownLinkHandler+Default.swift
//  MarkDownRange
//
//  Platform defaults used when the host doesn't supply its own handler. The
//  macOS implementation is the behavior the coordinator had inline before the
//  seam existed, moved verbatim so hosts see no change.
//

import Foundation
#if os(macOS)
	import AppKit
#else
	import UIKit
#endif

@MainActor final class DefaultMarkdownLinkHandler: MarkdownLinkHandler {
	static let shared = DefaultMarkdownLinkHandler()

	#if os(macOS)
	func openLink(_ url: URL, isMarkdownDocument: Bool) {
		guard isMarkdownDocument else {
			NSWorkspace.shared.open(url)
			return
		}
		NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, _ in
			if document == nil { NSWorkspace.shared.open(url) }
		}
	}

	func requestAccess(to url: URL, scope: MarkdownLinkAccessScope) -> URL? {
		let panel = NSOpenPanel()
		panel.allowsMultipleSelection = false
		panel.canCreateDirectories = false
		panel.directoryURL = url.deletingLastPathComponent()
		switch scope {
		case .file:
			panel.canChooseFiles = true
			panel.canChooseDirectories = false
			panel.message = "Select “\(url.lastPathComponent)” to allow Marker to open this link."
		case .folder:
			panel.canChooseFiles = false
			panel.canChooseDirectories = true
			panel.message = "Select a folder containing “\(url.lastPathComponent)” to allow this and sibling links."
		}
		guard panel.runModal() == .OK, let selected = panel.url else { return nil }
		let chosen = selected.standardizedFileURL.resolvingSymlinksInPath()
		let wanted = url.standardizedFileURL.resolvingSymlinksInPath()
		guard scope.grant(chosen, covers: wanted) else { return nil }
		let scoped = chosen.startAccessingSecurityScopedResource() ? chosen : nil
		NSDocumentController.shared.openDocument(withContentsOf: wanted, display: true) { document, _, _ in
			if document == nil { NSWorkspace.shared.open(wanted) }
		}
		return scoped
	}
	#else
	func openLink(_ url: URL, isMarkdownDocument: Bool) {
		// A host that wants markdown links to open in-app (rather than being
		// handed to whatever app claims the type) supplies its own handler.
		guard UIApplication.shared.canOpenURL(url) else { return }
		UIApplication.shared.open(url)
	}

	func requestAccess(to url: URL, scope: MarkdownLinkAccessScope) -> URL? {
		// Granting access on iOS means presenting a document picker, which
		// needs a view controller the framework doesn't own. Hosts supply a
		// handler for this; without one the link simply doesn't open.
		nil
	}
	#endif
}

public extension MarkdownLinkAccessScope {
	/// Whether `granted` actually covers `target` at this scope. A file grant
	/// must be the file itself; a folder grant must be an ancestor directory.
	/// Rejecting an unrelated selection matters — treating it as success would
	/// report access the sandbox never gave.
	func grant(_ granted: URL, covers target: URL) -> Bool {
		switch self {
		case .file:
			granted.path == target.path
		case .folder:
			target.path.hasPrefix(granted.path.hasSuffix("/") ? granted.path : granted.path + "/")
		}
	}
}
