//
//  ScrollBenchmarkSupport.swift
//  MarkDownRangeTests
//
//  Measures scrolling cost two ways:
//    • incremental viewport layout — what TextKit 2 does per frame on the good
//      path as content scrolls in/out (cheap), and
//    • full-document layout — the cost paid whenever something triggers
//      `ensureLayout(documentRange)`, which is the historical scroll-jank cause
//      (the old code re-laid-out the whole document on every scroll).
//  The ratio of the two is the point: if a code path forces full layout per
//  scroll, each frame costs `fullLayoutMs` instead of the per-frame number.
//
//  Caveat: the SwiftUI-hosted attachment views do NOT mount in this headless
//  harness (they need the live coordinator + run loop), so per-frame numbers
//  here exclude view-mount cost. The per-host instantiation cost is captured by
//  AttachmentSizingBenchmarks (~3 ms/attachment) — that's what a first mount
//  pays on screen.
//

#if os(macOS)
import AppKit
import Foundation
@testable import MarkDownRange

@MainActor
struct ScrollTiming {
	let label: String
	let docHeight: CGFloat
	let attachCount: Int
	/// Cost of laying out the whole document once — what `ensureLayout(documentRange)`
	/// costs. Several code paths can trigger it; doing so per scroll is jank.
	let fullLayoutMs: Double
	let medianFrameMs: Double
	let p90FrameMs: Double
	let maxFrameMs: Double

	/// How much slower a scroll frame is when it forces a full-document
	/// relayout instead of the incremental viewport pass.
	var fullRelayoutPenalty: Double { medianFrameMs > 0 ? fullLayoutMs / medianFrameMs : 0 }

	func report() {
		func f(_ v: Double) -> String { String(format: "%6.2f", v) }
		let head = label.padding(toLength: 20, withPad: " ", startingAt: 0)
		print("\(head) | att \(String(format: "%4d", attachCount)) docH \(String(format: "%7.0f", docHeight)) | "
			+ "incremental/frame med \(f(medianFrameMs)) p90 \(f(p90FrameMs)) max \(f(maxFrameMs)) ms | "
			+ "full-relayout \(String(format: "%7.1f", fullLayoutMs)) ms (\(String(format: "%.0f", fullRelayoutPenalty))× a frame)")
	}
}

@MainActor
enum ScrollBench {
	static func sweep(_ label: String, _ markdown: String, baseURL: URL? = nil, width: CGFloat = 800, viewport: CGFloat = 700, frames: Int = 60) async -> ScrollTiming {
		let inset: CGFloat = 24
		let blocks = MarkdownBlockParser.parse(markdown)
		let attributed = await MarkdownAttributedStringBuilder.build(
			blocks: blocks, theme: .default, fontSize: 16, baseURL: baseURL, availableWidth: width - inset * 2)

		let frame = NSRect(x: 0, y: 0, width: width, height: viewport)
		let textView = NSTextView(usingTextLayoutManager: true)
		textView.frame = frame
		textView.minSize = .zero
		textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
		textView.isVerticallyResizable = true
		textView.isHorizontallyResizable = false
		textView.autoresizingMask = [.width]
		textView.textContainerInset = NSSize(width: inset, height: 0)
		textView.textContainer?.widthTracksTextView = true
		textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

		let scrollView = NSScrollView(frame: frame)
		scrollView.hasVerticalScroller = true
		scrollView.documentView = textView

		// Host in a window so layout runs against a real clip view. (Attachment
		// hosting views still don't mount headlessly — see the file header.)
		let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
		window.contentView = scrollView

		textView.textStorage?.setAttributedString(attributed)

		guard let layoutManager = textView.textLayoutManager else {
			return ScrollTiming(label: label, docHeight: 0, attachCount: 0, fullLayoutMs: 0,
				medianFrameMs: 0, p90FrameMs: 0, maxFrameMs: 0)
		}

		let t0 = CFAbsoluteTimeGetCurrent()
		layoutManager.ensureLayout(for: layoutManager.documentRange)
		let fullLayoutMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000

		let docHeight = layoutManager.usageBoundsForTextContainer.height
		textView.frame = NSRect(x: 0, y: 0, width: width, height: max(docHeight, viewport))
		let attachCount = countAttachments(attributed)

		var frameTimes: [Double] = []
		let maxY = max(docHeight - viewport, 1)
		for i in 0...frames {
			let y = maxY * CGFloat(i) / CGFloat(frames)
			scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
			scrollView.reflectScrolledClipView(scrollView.contentView)
			let start = CFAbsoluteTimeGetCurrent()
			layoutManager.textViewportLayoutController.layoutViewport()
			frameTimes.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
		}
		frameTimes.sort()

		return ScrollTiming(
			label: label,
			docHeight: docHeight,
			attachCount: attachCount,
			fullLayoutMs: fullLayoutMs,
			medianFrameMs: percentile(frameTimes, 0.5),
			p90FrameMs: percentile(frameTimes, 0.9),
			maxFrameMs: frameTimes.last ?? 0
		)
	}

	private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
		guard !sorted.isEmpty else { return 0 }
		let index = min(sorted.count - 1, max(0, Int((Double(sorted.count) * p).rounded(.down))))
		return sorted[index]
	}

	private static func countAttachments(_ string: NSAttributedString) -> Int {
		var count = 0
		string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string.length)) { value, _, _ in
			if value != nil { count += 1 }
		}
		return count
	}
}
#endif
