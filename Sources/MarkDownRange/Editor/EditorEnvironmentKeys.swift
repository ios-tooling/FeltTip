//
//  EditorEnvironmentKeys.swift
//  MarkDownRange
//

import SwiftUI

private struct ShowLineNumbersKey: EnvironmentKey {
	static let defaultValue: Bool = false
}

private struct SyntaxHighlightingEnabledKey: EnvironmentKey {
	static let defaultValue: Bool = false
}

private struct MarkdownOptionsKey: EnvironmentKey {
	static let defaultValue: MarkdownOptions = .default
}

public extension EnvironmentValues {
	var showLineNumbers: Bool {
		get { self[ShowLineNumbersKey.self] }
		set { self[ShowLineNumbersKey.self] = newValue }
	}

	var syntaxHighlightingEnabled: Bool {
		get { self[SyntaxHighlightingEnabledKey.self] }
		set { self[SyntaxHighlightingEnabledKey.self] = newValue }
	}

	var markdownOptions: MarkdownOptions {
		get { self[MarkdownOptionsKey.self] }
		set { self[MarkdownOptionsKey.self] = newValue }
	}
}
