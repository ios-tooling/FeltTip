//
//  MarkdownSplitSyncLog.swift
//  MarkDownRange
//
//  Diagnostic gate for the split-view scroll-sync logging, sharing the edit
//  bridge's toggle: `defaults write <bundle-id> MDRDebugEditing -bool true`.
//

import Foundation

enum MarkdownSplitSyncLog {
	static let enabled = UserDefaults.standard.bool(forKey: "MDRDebugEditing")
}
