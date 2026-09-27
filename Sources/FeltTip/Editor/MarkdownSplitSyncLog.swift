//
//  MarkdownSplitSyncLog.swift
//  FeltTip
//
//  Diagnostic gate for the split-view scroll-sync logging, sharing the edit
//  bridge's toggle: `defaults write <bundle-id> FeltTipDebugEditing -bool true`.
//

import Foundation

enum MarkdownSplitSyncLog {
	static let enabled = UserDefaults.standard.bool(forKey: "FeltTipDebugEditing")
}
