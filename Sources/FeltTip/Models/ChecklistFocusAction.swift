//
//  ChecklistFocusAction.swift
//  FeltTip
//

import SwiftUI

private struct ChecklistFocusKey: EnvironmentKey {
	nonisolated(unsafe) static let defaultValue: (([String]) -> Void)? = nil
}

private struct ChecklistAddItemKey: EnvironmentKey {
	nonisolated(unsafe) static let defaultValue: (([String]) -> Void)? = nil
}

public extension EnvironmentValues {
	/// Callback invoked when the user asks to focus a task list.
	/// Parameter: the raw text of each list item, used by the host to identify which list was targeted.
	var onFocusChecklist: (([String]) -> Void)? {
		get { self[ChecklistFocusKey.self] }
		set { self[ChecklistFocusKey.self] = newValue }
	}

	/// Callback invoked when the user asks to append a new item to a task list.
	/// Parameter: the raw text of each existing list item.
	var onAddChecklistItem: (([String]) -> Void)? {
		get { self[ChecklistAddItemKey.self] }
		set { self[ChecklistAddItemKey.self] = newValue }
	}
}
