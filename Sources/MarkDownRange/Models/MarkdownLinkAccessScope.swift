//
//  MarkdownLinkAccessScope.swift
//  MarkDownRange
//

import SwiftUI

/// How much access to request when a clicked local link points at a file the
/// sandbox hasn't granted yet: just the file, or its enclosing folder (which
/// also covers sibling links so they don't re-prompt).
public enum MarkdownLinkAccessScope: String, Sendable, CaseIterable {
	case file
	case folder
}

private struct MarkdownLinkAccessScopeKey: EnvironmentKey {
	static let defaultValue: MarkdownLinkAccessScope = .file
}

public extension EnvironmentValues {
	var markdownLinkAccessScope: MarkdownLinkAccessScope {
		get { self[MarkdownLinkAccessScopeKey.self] }
		set { self[MarkdownLinkAccessScopeKey.self] = newValue }
	}
}
