//
//  LinkHoverTracker.swift
//  MarkdownRendering
//

import SwiftUI

@Observable @MainActor
public final class LinkDisplayState {
	public var displayedURL: String?
	private var hideTask: Task<Void, Never>?

	public init() {}

	public func show(url: String, duration: TimeInterval = 4) {
		hideTask?.cancel()
		displayedURL = url
		hideTask = Task {
			try? await Task.sleep(for: .seconds(duration))
			guard !Task.isCancelled else { return }
			withAnimation(.easeOut(duration: 0.3)) {
				displayedURL = nil
			}
		}
	}
}
