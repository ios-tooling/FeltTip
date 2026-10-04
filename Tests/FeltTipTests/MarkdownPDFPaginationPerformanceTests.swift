import CoreGraphics
import Testing
@testable import FeltTip

@Suite struct MarkdownPDFPaginationPerformanceTests {
	@Test("Indexed pagination preserves the prior planner's break semantics")
	func indexedPlannerMatchesReference() {
		let boxes = (0..<240).map { index in
			let top = CGFloat(index * 37)
			return (top: top, bottom: top + CGFloat(18 + index % 90))
		}
		let headings = stride(from: 80, through: 8_000, by: 173).map {
			(top: CGFloat($0), bottom: CGFloat($0 + 28))
		}

		let expected = referencePageTopOffsets(
			contentHeight: 9_000,
			printHeight: 720,
			boxes: boxes,
			headings: headings)
		let actual = MarkdownPDFRenderer.pageTopOffsets(
			contentHeight: 9_000,
			printHeight: 720,
			boxes: boxes,
			headings: headings)

		#expect(actual == expected)
	}

	@Test(
		"A long report pagination plan remains responsive",
		.enabled(if: ProcessInfo.processInfo.environment["FELTTIP_RUN_BENCHMARKS"] == "1")
	)
	func longReportPlannerRemainsResponsive() {
		let boxes = (0..<30_000).map { index in
			let top = CGFloat(index * 40)
			return (top: top, bottom: top + CGFloat(20 + index % 120))
		}
		let headings = stride(from: 200, through: 1_199_000, by: 400).map {
			(top: CGFloat($0), bottom: CGFloat($0 + 32))
		}

		let clock = ContinuousClock()
		var pages: [CGFloat] = []
		let elapsed = clock.measure {
			pages = MarkdownPDFRenderer.pageTopOffsets(
				contentHeight: 1_200_000,
				printHeight: 720,
				boxes: boxes,
				headings: headings)
		}

		#expect(pages.count > 1_600)
		#expect(elapsed < .seconds(1))
	}

	@Test("Large geometry JSON decoding keeps the main actor responsive")
	@MainActor
	func geometryDecodeRunsOffMainActor() async {
		let entry = "[12345.5,42.25]"
		let count = 150_000
		let raw = "[" + Array(
			repeating: entry, count: count
		).joined(separator: ",") + "]"
		var mainActorTicks = 0
		let ticker = Task { @MainActor in
			while !Task.isCancelled {
				mainActorTicks += 1
				await Task.yield()
			}
		}
		let boxes = await MarkdownPDFRenderer.decodeBoxesJSON(raw)
		ticker.cancel()
		await ticker.value

		#expect(boxes.count == count)
		// One turn is sufficient to prove the detached decoder did not occupy
		// MainActor. Requiring several turns made scheduler load, rather than
		// actor isolation, part of this correctness test.
		#expect(mainActorTicks >= 1)
	}

	@Test("Invalid page geometry cannot enter a non-progressing pagination loop")
	func invalidGeometryIsRejected() {
		for printHeight in [CGFloat.zero, -1, .infinity, .nan] {
			#expect(MarkdownPDFRenderer.pageTopOffsets(
				contentHeight: 1_000,
				printHeight: printHeight,
				boxes: [],
				headings: []).isEmpty)
		}
		#expect(MarkdownPDFRenderer.pageTopOffsets(
			contentHeight: .infinity,
			printHeight: 720,
			boxes: [],
			headings: []).isEmpty)
	}

	@Test("An adversarial document cannot create an unbounded page plan")
	func excessivePagePlanIsRejected() {
		let pages = MarkdownPDFRenderer.pageTopOffsets(
			contentHeight: CGFloat(MarkdownPDFRenderer.maximumPageCount + 1) * 720,
			printHeight: 720,
			boxes: [],
			headings: [])

		#expect(pages.isEmpty)
	}

	@Test("Cancelled PDF capture stops after its in-flight page")
	@MainActor
	func cancelledCaptureStopsBeforeRemainingPages() async {
		var captures: [(top: CGFloat, height: CGFloat)] = []

		let captureTask = Task { @MainActor in
			await MarkdownPDFRenderer.forEachPageSlice(
				tops: [0, 720, 1_440, 2_160],
				contentHeight: 2_500,
				printHeight: 720
			) { top, height in
				captures.append((top, height))
				withUnsafeCurrentTask { $0?.cancel() }
				await Task.yield()
			}
		}
		let completed = await captureTask.value

		#expect(!completed)
		#expect(captures.count == 1)
		#expect(captures.first?.top == 0)
		#expect(captures.first?.height == 720)
	}

	/// The pre-optimization implementation, retained only as a small-input
	/// oracle so the indexed planner cannot change page-break behavior.
	private func referencePageTopOffsets(
		contentHeight: CGFloat,
		printHeight: CGFloat,
		boxes: [(top: CGFloat, bottom: CGFloat)],
		headings: [(top: CGFloat, bottom: CGFloat)]
	) -> [CGFloat] {
		var tops: [CGFloat] = [0]
		var current: CGFloat = 0
		while current + printHeight < contentHeight {
			var bottom = current + printHeight
			for box in boxes
			where box.top > current && box.top < bottom && box.bottom > bottom {
				if box.bottom - box.top <= printHeight {
					bottom = min(bottom, box.top)
				}
			}
			for heading in headings
			where heading.top > current && heading.bottom <= bottom {
				let next = boxes.filter {
					$0.top > heading.bottom - 1
				}.map(\.top).min()
				if let next, next >= bottom - 0.5 {
					bottom = min(bottom, heading.top)
				}
			}
			if bottom <= current { bottom = current + printHeight }
			tops.append(bottom)
			current = bottom
		}
		return tops
	}
}
