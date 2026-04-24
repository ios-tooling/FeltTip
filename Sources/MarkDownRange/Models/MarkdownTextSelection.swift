//
//  MarkdownTextSelection.swift
//  MarkDownRange
//

import SwiftUI

private struct MarkdownTextSelectionKey: EnvironmentKey {
	static let defaultValue: Bool = true
}

public extension EnvironmentValues {
	/// When false, rendered markdown text will not be user-selectable.
	/// Use to let tap gestures on a parent view receive clicks instead.
	var markdownTextSelectionEnabled: Bool {
		get { self[MarkdownTextSelectionKey.self] }
		set { self[MarkdownTextSelectionKey.self] = newValue }
	}
}
