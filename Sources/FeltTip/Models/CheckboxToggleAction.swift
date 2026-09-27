//
//  CheckboxToggleAction.swift
//  FeltTip
//

import SwiftUI

private struct CheckboxToggleKey: EnvironmentKey {
	nonisolated(unsafe) static let defaultValue: ((Int, Bool) -> Void)? = nil
}

public extension EnvironmentValues {
	/// Callback invoked when a task-list checkbox is toggled.
	/// Parameters: (checkboxIndex, newIsChecked)
	var onCheckboxToggle: ((Int, Bool) -> Void)? {
		get { self[CheckboxToggleKey.self] }
		set { self[CheckboxToggleKey.self] = newValue }
	}
}
