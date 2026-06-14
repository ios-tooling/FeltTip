//
//  MarkdownPDFRenderer+Pagination.swift
//  MarkDownRange
//

#if os(macOS)
import CoreGraphics
import Foundation
import WebKit

extension MarkdownPDFRenderer {
	/// Captures the laid-out web view into letter-sized pages. Each page is
	/// rendered at 1:1 via `WKPDFConfiguration.rect` rather than slicing one
	/// giant PDF — `createPDF` clamps a single page to ~14400pt, which silently
	/// truncates and mis-scales documents taller than ~20 pages. Page breaks are
	/// nudged up so an element in `unbreakable` is never split across pages.
	static func paginate(webView: WKWebView, contentHeight: CGFloat, margin: CGFloat,
						  unbreakable: [(top: CGFloat, height: CGFloat)],
						  headings: [(top: CGFloat, height: CGFloat)]) async -> Data? {
		let printW = pageWidth - 2 * margin
		let printH = pageHeight - 2 * margin
		let boxes  = unbreakable.map { (top: $0.top, bottom: $0.top + $0.height) }
		let heads  = headings.map { (top: $0.top, bottom: $0.top + $0.height) }
		let tops   = pageTopOffsets(contentHeight: contentHeight, printHeight: printH, boxes: boxes, headings: heads)

		let out = NSMutableData()
		guard let consumer = CGDataConsumer(data: out as CFMutableData) else { return nil }
		var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
		guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

		for (i, top) in tops.enumerated() {
			let nextTop  = i + 1 < tops.count ? tops[i + 1] : contentHeight
			let contentH = min(printH, nextTop - top)

			let config = WKPDFConfiguration()
			config.rect = CGRect(x: 0, y: top, width: printW, height: contentH)
			guard let data = try? await withCheckedThrowingContinuation({ (c: CheckedContinuation<Data, Error>) in
				webView.createPDF(configuration: config) { c.resume(with: $0) }
			}),
			let provider = CGDataProvider(data: data as CFData),
			let slice = CGPDFDocument(provider)?.page(at: 1)
			else { continue }

			ctx.beginPDFPage(nil)
			ctx.saveGState()
			// Top-align the slice in the printable area; a short page (break
			// pulled up) leaves the remaining space blank at the bottom.
			ctx.translateBy(x: margin, y: margin + (printH - contentH))
			ctx.drawPDFPage(slice)
			ctx.restoreGState()
			ctx.endPDFPage()
		}

		ctx.closePDF()
		return out as Data
	}

	/// CSS-top offset where each output page begins. A page would normally end
	/// `printHeight` below its start, but if an element that fits on one page
	/// straddles that boundary, the break is pulled up to the element's top so
	/// it starts fresh on the next page.
	private static func pageTopOffsets(contentHeight: CGFloat, printHeight: CGFloat,
									   boxes: [(top: CGFloat, bottom: CGFloat)],
									   headings: [(top: CGFloat, bottom: CGFloat)]) -> [CGFloat] {
		var tops: [CGFloat] = [0]
		var current: CGFloat = 0

		while current + printHeight < contentHeight {
			var bottom = current + printHeight

			// Don't split an element across the boundary.
			for box in boxes where box.top > current && box.top < bottom && box.bottom > bottom {
				if box.bottom - box.top <= printHeight { bottom = min(bottom, box.top) }
			}

			// Don't leave a heading stranded as the last item on the page: if a
			// heading sits on this page with no following content before the
			// break, pull the break up so it starts the next page.
			for h in headings where h.top > current && h.bottom <= bottom {
				let nextContentTop = boxes.filter { $0.top > h.bottom - 1 }.map(\.top).min()
				if let next = nextContentTop, next >= bottom - 0.5 { bottom = min(bottom, h.top) }
			}

			if bottom <= current { bottom = current + printHeight }   // element too tall to help; force progress
			tops.append(bottom)
			current = bottom
		}
		return tops
	}
}
#endif
