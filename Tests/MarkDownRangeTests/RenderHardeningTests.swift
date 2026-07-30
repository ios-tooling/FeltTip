//
//  RenderHardeningTests.swift
//  MarkDownRangeTests
//

import Foundation
import Testing
@testable import MarkDownRange
#if os(macOS)
import WebKit
#endif

#if os(macOS)
@MainActor
private final class RenderCancellationFlag {
	var wasCancelled = false
}
#endif

@Suite("Render hardening")
struct RenderHardeningTests {
	@Test("Live WebView documents block remote subresources by default")
	func remoteResourcesDefaultToBlocked() async {
		let rendered = await MarkdownRenderService.shared.documentHTML(
			markdown: "![pixel](https://tracker.example/id.png)",
			theme: .default,
			fontSize: 16,
			includeSourceOffsets: false,
			interactiveCheckboxes: false,
			embedMermaidEngine: false,
			allowRemoteResources: false
		)

		#expect(rendered.html.contains("Content-Security-Policy"))
		#expect(rendered.html.contains("connect-src 'none'"))
		#expect(rendered.html.contains("img-src data: markerlocalres:;"))
		#expect(!rendered.html.contains("img-src data: markerlocalres: https:"))
	}

	@Test("Trusted hosts can explicitly allow remote images and media")
	func remoteResourcesRequireOptIn() async {
		let rendered = await MarkdownRenderService.shared.documentHTML(
			markdown: "trusted",
			theme: .default,
			fontSize: 16,
			includeSourceOffsets: false,
			interactiveCheckboxes: false,
			embedMermaidEngine: false,
			allowRemoteResources: true
		)

		#expect(rendered.html.contains("img-src data: markerlocalres: https: http:"))
		#expect(rendered.html.contains("media-src data: markerlocalres: https: http:"))
	}

	#if os(macOS)
	@Test("MarkdownWebView itself defaults to the blocked policy")
	@MainActor
	func webViewDefaultsToBlocked() {
		let view = MarkdownWebView(text: "text", theme: .default, fontSize: 16)
		#expect(!view.allowsRemoteResources)
		#expect(view.allowRemoteResources(true).allowsRemoteResources)
	}

	@Test("Separate WebViews do not share a render queue")
	@MainActor
	func webViewsOwnIndependentRenderServices() {
		let first = MarkdownWebView(
			text: "large background document", theme: .default, fontSize: 16
		).makeCoordinator()
		let second = MarkdownWebView(
			text: "active document", theme: .default, fontSize: 16
		).makeCoordinator()

		#expect(ObjectIdentifier(first.renderService)
			!= ObjectIdentifier(second.renderService))
	}

	@Test("Closing a WebView cancels outstanding render work")
	@MainActor
	func closingWebViewCancelsOutstandingWork() async {
		let renderFlag = RenderCancellationFlag()
		let swapFlag = RenderCancellationFlag()
		var coordinator: MarkdownWebView.Coordinator? = MarkdownWebView(
			text: "large document", theme: .default, fontSize: 16
		).makeCoordinator()

		coordinator?.renderTask = cancellationProbe(flag: renderFlag)
		coordinator?.pendingSwap = cancellationProbe(flag: swapFlag)
		coordinator = nil

		for _ in 0..<50 where !renderFlag.wasCancelled || !swapFlag.wasCancelled {
			try? await Task.sleep(for: .milliseconds(10))
		}

		#expect(renderFlag.wasCancelled)
		#expect(swapFlag.wasCancelled)
	}

	@Test("Patch fallback serialization is tracked as cancellable render work")
	@MainActor
	func patchFallbackSerializationIsTracked() async {
		let coordinator = MarkdownWebView(
			text: "document", theme: .default, fontSize: 16
		).makeCoordinator()
		let webView = WKWebView()
		let rendered = MarkdownRenderService.BlockResult(
			fragments: [MarkdownBlockFragment(html: "<p>fallback</p>")],
			patch: nil,
			patchHTMLJSON: nil,
			bodyJSON: nil)

		coordinator.apply(rendered, into: webView, thenPlaceCaret: nil)
		let fallbackTask = coordinator.renderTask

		#expect(fallbackTask != nil)
		fallbackTask?.cancel()
		await fallbackTask?.value
	}

	@Test("PDF WebView blocks remote subresources unless explicitly allowed")
	@MainActor
	func pdfRemoteResourcesRequireOptIn() {
		let html = "<!doctype html><html><head></head><body><img src=\"https://tracker.example/pixel\"></body></html>"
		let blocked = MarkdownPDFRenderer.securingForWebView(
			html, allowRemoteResources: false)
		let allowed = MarkdownPDFRenderer.securingForWebView(
			html, allowRemoteResources: true)

		#expect(blocked.contains("Content-Security-Policy"))
		#expect(blocked.contains("img-src data: markerlocalres:;"))
		#expect(!blocked.contains("img-src data: markerlocalres: https:"))
		#expect(allowed.contains("img-src data: markerlocalres: https: http:"))
	}
	#endif

	@Test("Full-swap payload is prepared only when no incremental baseline exists")
	func fullSwapPayloadMatchesFragments() async throws {
		let result = await MarkdownRenderService.shared.blockResult(
			markdown: "# Heading\n\nOne **two** three.\n\n- four\n- five\n",
			theme: .default,
			fontSize: 16,
			includeSourceOffsets: true,
			interactiveCheckboxes: false
		)
		#expect(result.patch == nil)
		let bodyJSON = try #require(result.bodyJSON)
		let data = try #require(bodyJSON.data(using: .utf8))
		let decoded = try JSONDecoder().decode(String.self, from: data)
		#expect(decoded == result.fragments.map(\.html).joined())
	}

	@Test("Incremental render serializes only the changed block payload")
	func incrementalRenderSkipsWholeBodySerialization() async throws {
		let source = (0..<1_500)
			.map { "Paragraph \($0) with **bold text** and a [link](https://example.com/\($0))." }
			.joined(separator: "\n\n")
		let baseline = await MarkdownRenderService.shared.blockFragments(
			markdown: source,
			theme: .default,
			fontSize: 16,
			includeSourceOffsets: true,
			interactiveCheckboxes: false)
		let edited = source.replacingOccurrences(
			of: "Paragraph 700 ",
			with: "Paragraph 700X ")
		let result = await MarkdownRenderService.shared.blockResult(
			markdown: edited,
			theme: .default,
			fontSize: 16,
			includeSourceOffsets: true,
			interactiveCheckboxes: false,
			baseline: baseline)

		let patch = try #require(result.patch)
		#expect(patch.removeCount == 1)
		#expect(patch.html.count == 1)
		#expect(result.patchHTMLJSON != nil)
		#expect(result.bodyJSON == nil)
	}

	@Test("Cancelled block rendering stops before publishing a complete large result")
	func cancellationStopsBlockGeneration() async {
		let blockCount = 12_000
		let markdown = (0..<blockCount)
			.map { "Paragraph \($0) with **bold text**, `code`, and [link](https://example.com/\($0))." }
			.joined(separator: "\n\n")
		let task = Task {
			await MarkdownRenderService.shared.blockFragments(
				markdown: markdown,
				theme: .default,
				fontSize: 16,
				includeSourceOffsets: true,
				interactiveCheckboxes: false
			)
		}
		await Task.yield()
		task.cancel()
		let fragments = await task.value
		#expect(fragments.count < blockCount)
	}

	@Test("Cancelled fallback serialization skips obsolete whole-body work")
	func cancellationStopsFallbackSerialization() async {
		let service = MarkdownRenderService()
		let fragments = (0..<10_000).map {
			MarkdownBlockFragment(html: "<p>Paragraph \($0)</p>")
		}
		let task = Task {
			withUnsafeCurrentTask { $0?.cancel() }
			return await service.bodyJSON(for: fragments)
		}

		#expect(await task.value == nil)
	}

	@Test("Cancelled full-document serialization does not publish wrapped HTML")
	func cancellationStopsFullDocumentSerialization() async {
		let service = MarkdownRenderService()
		let markdown = (0..<10_000)
			.map { "Paragraph \($0) with **bold text** and [link](https://example.com/\($0))." }
			.joined(separator: "\n\n")
		let task = Task {
			withUnsafeCurrentTask { $0?.cancel() }
			return await service.documentHTML(
				markdown: markdown,
				theme: .default,
				fontSize: 16,
				includeSourceOffsets: true,
				interactiveCheckboxes: false,
				embedMermaidEngine: false)
		}

		let rendered = await task.value
		#expect(rendered.html.isEmpty)
		#expect(rendered.fragments.isEmpty)
	}

	@Test("Image-region collection remains linear on linked-image-heavy HTML")
	func linkedImageCollectionScales() {
		let count = 4_000
		let html = (0..<count).map {
			"<a href=\"https://example.com/\($0)\"><img src=\"image-\($0).png\" alt=\"\($0)\"></a>"
		}.joined()
		let clock = ContinuousClock()
		let start = clock.now
		let hits = ImageRegions.collect(in: html)
		let elapsed = start.duration(to: clock.now)

		#expect(hits.count == count)
		#expect(hits.first?.link == "https://example.com/0")
		#expect(hits.last?.link == "https://example.com/\(count - 1)")
		#expect(elapsed < .seconds(2), "linked-image scan took \(elapsed)")
	}

	#if os(macOS)
	@MainActor
	private func cancellationProbe(
		flag: RenderCancellationFlag
	) -> Task<Void, Never> {
		Task { @MainActor in
			do {
				try await Task.sleep(for: .seconds(5))
			} catch {
				flag.wasCancelled = Task.isCancelled
			}
		}
	}
	#endif
}
