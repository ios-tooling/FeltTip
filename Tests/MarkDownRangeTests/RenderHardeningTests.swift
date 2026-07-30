//
//  RenderHardeningTests.swift
//  MarkDownRangeTests
//

import Foundation
import Testing
@testable import MarkDownRange

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

	@Test("Full-swap payload is prepared with the fragments off the main actor")
	func fullSwapPayloadMatchesFragments() async throws {
		let result = await MarkdownRenderService.shared.blockResult(
			markdown: "# Heading\n\nOne **two** three.\n\n- four\n- five\n",
			theme: .default,
			fontSize: 16,
			includeSourceOffsets: true,
			interactiveCheckboxes: false
		)
		let data = try #require(result.bodyJSON.data(using: .utf8))
		let decoded = try JSONDecoder().decode(String.self, from: data)
		#expect(decoded == result.fragments.map(\.html).joined())
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
}
