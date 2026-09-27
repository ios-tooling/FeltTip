//
//  MarkdownPreparedWebRender.swift
//  FeltTip
//
//  Starts the first styled render before SwiftUI constructs WKWebView. The
//  coordinator consumes it only when every render-affecting input still
//  matches; otherwise it uses its normal per-document renderer.
//

import SwiftUI

public final class MarkdownPreparedWebRender: @unchecked Sendable {
	struct Configuration: Equatable, Sendable {
		let markdown: String
		let theme: MarkdownTheme
		let fontSize: CGFloat
		let includeSourceOffsets: Bool
		let interactiveCheckboxes: Bool
		let embedMermaidEngine: Bool
		let allowRemoteResources: Bool
	}

	private let configuration: Configuration
	private let task: Task<MarkdownRenderService.DocumentHTML, Never>
	private let state: State

	private final class State: @unchecked Sendable {
		private let lock = NSLock()
		private var result: MarkdownRenderService.DocumentHTML?
		private var consumed = false

		var wasConsumed: Bool { lock.withLock { consumed } }

		func store(_ result: MarkdownRenderService.DocumentHTML) {
			lock.withLock { self.result = result }
		}

		func consumeCompleted() -> MarkdownRenderService.DocumentHTML? {
			lock.withLock {
				guard let result else { return nil }
				consumed = true
				return result
			}
		}

		func markConsumed() {
			lock.withLock { consumed = true }
		}
	}

	var wasConsumed: Bool { state.wasConsumed }

	public init(
		markdown: String,
		theme: MarkdownTheme,
		fontSize: CGFloat,
		includeSourceOffsets: Bool,
		interactiveCheckboxes: Bool,
		embedMermaidEngine: Bool,
		allowRemoteResources: Bool
	) {
		let configuration = Configuration(
			markdown: markdown,
			theme: theme,
			fontSize: fontSize,
			includeSourceOffsets: includeSourceOffsets,
			interactiveCheckboxes: interactiveCheckboxes,
			embedMermaidEngine: embedMermaidEngine,
			allowRemoteResources: allowRemoteResources)
		self.configuration = configuration
		let state = State()
		self.state = state
		self.task = Task.detached(priority: .userInitiated) {
			let renderService = MarkdownRenderService()
			let result = await renderService.documentHTML(
				markdown: configuration.markdown,
				theme: configuration.theme,
				fontSize: configuration.fontSize,
				includeSourceOffsets: configuration.includeSourceOffsets,
				interactiveCheckboxes: configuration.interactiveCheckboxes,
				embedMermaidEngine: configuration.embedMermaidEngine,
				allowRemoteResources: configuration.allowRemoteResources)
			state.store(result)
			return result
		}
	}

	/// Returns immediately when the speculative render has already completed.
	/// This lets WKWebView navigation begin inside updateNSView's current main-
	/// actor turn instead of queuing behind the rest of first-window layout.
	func completedResult(matching configuration: Configuration) -> MarkdownRenderService.DocumentHTML? {
		guard self.configuration == configuration else { return nil }
		return state.consumeCompleted()
	}

	func result(matching configuration: Configuration) async -> MarkdownRenderService.DocumentHTML? {
		guard self.configuration == configuration else { return nil }
		state.markConsumed()
		return await task.value
	}

	/// Stop speculative work when the host discovers that the decoded document
	/// will open raw or with a different render configuration.
	public func cancel() {
		task.cancel()
	}
}
