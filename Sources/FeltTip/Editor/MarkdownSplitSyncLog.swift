//
//  MarkdownSplitSyncLog.swift
//  FeltTip
//
//  Diagnostic gate for the split-view scroll-sync logging, sharing the edit
//  bridge's toggle: `defaults write <bundle-id> FeltTipDebugEditing -bool true`.
//

import Foundation

enum MarkdownSplitSyncLog {
	/// Also honors `FELTTIP_SPLITSYNC_LOG=1` so `swift test` runs can log.
	static let enabled = UserDefaults.standard.bool(forKey: "FeltTipDebugEditing")
		|| ProcessInfo.processInfo.environment["FELTTIP_SPLITSYNC_LOG"] != nil
}
