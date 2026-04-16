//
//  EditorEnvironmentKeys.swift
//  MarkDownRange
//

#if os(macOS)
import SwiftUI

private struct ShowLineNumbersKey: EnvironmentKey {
	nonisolated(unsafe) static let defaultValue: Bool = false
}

private struct SyntaxHighlightingEnabledKey: EnvironmentKey {
	nonisolated(unsafe) static let defaultValue: Bool = false
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
}
#endif
