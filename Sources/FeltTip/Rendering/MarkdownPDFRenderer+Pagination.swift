//
//  MarkdownPDFRenderer+Pagination.swift
//  FeltTip
//

import CoreGraphics
import Foundation
import WebKit

extension MarkdownPDFRenderer {
	static let pdfCaptureTimeout: Duration = .seconds(15)
	static let javaScriptTimeout: Duration = .seconds(5)
	nonisolated static let maximumPageCount = 2_000

	private struct JavaScriptResult: @unchecked Sendable {
		let value: Any?
	}

	/// Captures the laid-out web view into letter-sized pages. Each page is
	/// rendered at 1:1 via `WKPDFConfiguration.rect` rather than slicing one
	/// giant PDF — `createPDF` clamps a single page to ~14400pt, which silently
	/// truncates and mis-scales documents taller than ~20 pages. Page breaks are
	/// nudged up so an element in `unbreakable` is never split across pages.
	static func paginate(webView: WKWebView, contentHeight: CGFloat, margin: CGFloat,
						  unbreakable: [(top: CGFloat, height: CGFloat)],
						  headings: [(top: CGFloat, height: CGFloat)],
						  links: [PDFLinkRegion] = []) async -> Data? {
		let printW = pageWidth - 2 * margin
		let printH = pageHeight - 2 * margin
		let boxes  = unbreakable.map { (top: $0.top, bottom: $0.top + $0.height) }
		let heads  = headings.map { (top: $0.top, bottom: $0.top + $0.height) }
		let planner = Task.detached(priority: .userInitiated) {
			pageTopOffsets(
				contentHeight: contentHeight,
				printHeight: printH,
				boxes: boxes,
				headings: heads)
		}
		let tops = await withTaskCancellationHandler(
			operation: { await planner.value },
			onCancel: { planner.cancel() })
		guard !Task.isCancelled, !tops.isEmpty else { return nil }

		let out = NSMutableData()
		guard let consumer = CGDataConsumer(data: out as CFMutableData) else { return nil }
		var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
		guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

		let completed = await forEachPageSlice(
			tops: tops,
			contentHeight: contentHeight,
			printHeight: printH
		) { top, contentH in
			let config = WKPDFConfiguration()
			config.rect = CGRect(
				x: 0, y: top, width: printW, height: contentH)
			guard let data = try? await capturePDF(start: { completion in
				webView.createPDF(configuration: config, completionHandler: completion)
			}),
			let provider = CGDataProvider(data: data as CFData),
			let slice = CGPDFDocument(provider)?.page(at: 1)
			else { return false }

			ctx.beginPDFPage(nil)
			ctx.saveGState()
			// Top-align the slice in the printable area; a short page (break
			// pulled up) leaves the remaining space blank at the bottom.
			ctx.translateBy(x: margin, y: margin + (printH - contentH))
			ctx.drawPDFPage(slice)
			ctx.restoreGState()

			let sliceBottom = top + contentH
			for link in links where link.top < sliceBottom && link.top + link.height > top {
				let clippedTop = max(link.top, top)
				let clippedBottom = min(link.top + link.height, sliceBottom)
				let clippedHeight = clippedBottom - clippedTop
				guard clippedHeight > 0 else { continue }
				let rect = CGRect(
					x: margin + link.left,
					y: pageHeight - margin - (clippedTop - top) - clippedHeight,
					width: link.width,
					height: clippedHeight)
				ctx.setURL(link.url as CFURL, for: rect)
			}
			ctx.endPDFPage()
			return true
		}

		ctx.closePDF()
		return completed ? out as Data : nil
	}

	/// WebKit has failed to call its PDF completion handler after a content-
	/// process termination on some OS releases. Convert the callback to async
	/// with an independent deadline so one lost callback cannot suspend the
	/// entire export forever. `AsyncThrowingStream.Continuation` safely ignores
	/// a late callback after timeout or cancellation.
	static func capturePDF(
		timeout: Duration = pdfCaptureTimeout,
		start: (@escaping @Sendable (Result<Data, Error>) -> Void) -> Void
	) async throws -> Data {
		try Task.checkCancellation()
		let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream(
			bufferingPolicy: .bufferingNewest(1))
		start { result in
			switch result {
			case .success(let data):
				continuation.yield(data)
				continuation.finish()
			case .failure(let error):
				continuation.finish(throwing: error)
			}
		}
		let timeoutTask = Task {
			do { try await Task.sleep(for: timeout) }
			catch { return }
			continuation.finish(throwing: URLError(.timedOut))
		}
		return try await withTaskCancellationHandler {
			defer { timeoutTask.cancel() }
			var iterator = stream.makeAsyncIterator()
			guard let data = try await iterator.next() else {
				throw URLError(.unknown)
			}
			return data
		} onCancel: {
			continuation.finish(throwing: CancellationError())
		}
	}

	/// `evaluateJavaScript` can lose its completion callback when WebKit's
	/// content process terminates. Use the callback API with a deadline rather
	/// than awaiting the system async overlay indefinitely.
	static func evaluateJavaScript(
		_ script: String,
		in webView: WKWebView,
		timeout: Duration = javaScriptTimeout
	) async throws -> Any? {
		try await evaluateJavaScript(timeout: timeout) { completion in
			webView.evaluateJavaScript(script, completionHandler: completion)
		}
	}

	static func evaluateJavaScript(
		timeout: Duration = javaScriptTimeout,
		start: (@escaping @Sendable (Any?, Error?) -> Void) -> Void
	) async throws -> Any? {
		try Task.checkCancellation()
		let (stream, continuation) = AsyncThrowingStream<JavaScriptResult, Error>.makeStream(
			bufferingPolicy: .bufferingNewest(1))
		start { value, error in
			if let error {
				continuation.finish(throwing: error)
			} else {
				continuation.yield(JavaScriptResult(value: value))
				continuation.finish()
			}
		}
		let timeoutTask = Task {
			do { try await Task.sleep(for: timeout) }
			catch { return }
			continuation.finish(throwing: URLError(.timedOut))
		}
		return try await withTaskCancellationHandler {
			defer { timeoutTask.cancel() }
			var iterator = stream.makeAsyncIterator()
			guard let result = try await iterator.next() else {
				throw URLError(.unknown)
			}
			return result.value
		} onCancel: {
			continuation.finish(throwing: CancellationError())
		}
	}

	/// Runs the inherently MainActor-bound WebKit page captures while checking
	/// cancellation around every asynchronous slice. `WKWebView.createPDF`
	/// itself is not cancellable, but a cancelled long export must not continue
	/// capturing every remaining page after the in-flight slice returns.
	static func forEachPageSlice(
		tops: [CGFloat],
		contentHeight: CGFloat,
		printHeight: CGFloat,
		capture: (CGFloat, CGFloat) async -> Bool
	) async -> Bool {
		for (index, top) in tops.enumerated() {
			guard !Task.isCancelled else { return false }
			let nextTop = index + 1 < tops.count
				? tops[index + 1] : contentHeight
			guard await capture(top, min(printHeight, nextTop - top)) else { return false }
			guard !Task.isCancelled else { return false }
		}
		return true
	}

	/// CSS-top offset where each output page begins. A page would normally end
	/// `printHeight` below its start, but if an element that fits on one page
	/// straddles that boundary, the break is pulled up to the element's top so
	/// it starts fresh on the next page.
	nonisolated static func pageTopOffsets(
		contentHeight: CGFloat,
		printHeight: CGFloat,
		boxes: [(top: CGFloat, bottom: CGFloat)],
		headings: [(top: CGFloat, bottom: CGFloat)]
	) -> [CGFloat] {
		guard contentHeight.isFinite, contentHeight >= 0,
			printHeight.isFinite, printHeight > 0 else { return [] }
		// DOM queries normally arrive in document order, but sorting here makes
		// the planner robust to nested elements and lets each page inspect only
		// its own candidates. The old implementation rescanned every box for
		// every page, then allocated a filter/map array over every box for every
		// heading — effectively pages × headings × elements on long reports.
		let boxes = boxes.sorted {
			$0.top == $1.top ? $0.bottom < $1.bottom : $0.top < $1.top
		}
		let headings = headings.sorted {
			$0.top == $1.top ? $0.bottom < $1.bottom : $0.top < $1.top
		}
		let boxTops = boxes.map(\.top)
		let headingTops = headings.map(\.top)
		var tops: [CGFloat] = [0]
		var current: CGFloat = 0

		while current + printHeight < contentHeight {
			guard !Task.isCancelled else { return [] }
			guard tops.count < maximumPageCount else { return [] }
			var bottom = current + printHeight

			// Don't split an element across the boundary.
			var boxIndex = upperBound(current, in: boxTops)
			while boxIndex < boxes.count, boxes[boxIndex].top < bottom {
				let box = boxes[boxIndex]
				if box.bottom > bottom,
				   box.bottom - box.top <= printHeight {
					bottom = min(bottom, box.top)
				}
				boxIndex += 1
			}

			// Don't leave a heading stranded as the last item on the page: if a
			// heading sits on this page with no following content before the
			// break, pull the break up so it starts the next page.
			var headingIndex = upperBound(current, in: headingTops)
			while headingIndex < headings.count,
				  headings[headingIndex].top < bottom {
				let heading = headings[headingIndex]
				if heading.bottom <= bottom {
					let nextIndex = upperBound(
						heading.bottom - 1, in: boxTops)
					if nextIndex < boxTops.count,
					   boxTops[nextIndex] >= bottom - 0.5 {
						bottom = min(bottom, heading.top)
					}
				}
				headingIndex += 1
			}

			if bottom <= current { bottom = current + printHeight }   // element too tall to help; force progress
			tops.append(bottom)
			current = bottom
		}
		return tops
	}

	nonisolated private static func upperBound(
		_ value: CGFloat, in sortedValues: [CGFloat]
	) -> Int {
		var lower = 0
		var upper = sortedValues.count
		while lower < upper {
			let middle = lower + (upper - lower) / 2
			if sortedValues[middle] <= value {
				lower = middle + 1
			} else {
				upper = middle
			}
		}
		return lower
	}
}
