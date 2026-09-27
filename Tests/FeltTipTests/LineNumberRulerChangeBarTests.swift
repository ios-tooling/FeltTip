#if os(macOS)
	import AppKit
	import Testing
	@testable import FeltTip

/// Renders the line-number ruler offscreen and checks that change indicators
/// actually put colored pixels in the gutter: green for added, blue for
/// modified, red ticks for deletions.
@Suite(.serialized) @MainActor struct LineNumberRulerChangeBarTests {
	@Test func changeBarsRenderInTheGutter() throws {
		let (ruler, _) = makeRuler(text: "alpha\nbravo\ncharlie\ndelta")
		ruler.lineChanges = MarkdownLineChanges(
			changedLines: [0: .added, 2: .modified],
			deletionsAfter: [0],
			changedRanges: [],
			deletionOffsets: []
		)
		let colors = try renderedColors(of: ruler)
		#expect(colors.contains(where: isGreenish), "no added-line bar drawn")
		#expect(colors.contains(where: isBlueish), "no modified-line bar drawn")
		#expect(colors.contains(where: isReddish), "no deletion tick drawn")
	}

	@Test func noChangesDrawsNoBars() throws {
		let (ruler, _) = makeRuler(text: "alpha\nbravo")
		let colors = try renderedColors(of: ruler)
		#expect(!colors.contains(where: isGreenish))
		#expect(!colors.contains(where: isBlueish))
		#expect(!colors.contains(where: isReddish))
	}

	@Test func barsOnlyGutterIsNarrow() throws {
		let (ruler, _) = makeRuler(text: "alpha\nbravo")
		ruler.lineChanges = MarkdownLineChanges(changedLines: [0: .added], deletionsAfter: [], changedRanges: [], deletionOffsets: [])
		_ = try renderedColors(of: ruler)  // first draw builds line starts + numbers width
		#expect(ruler.ruleThickness > 12, "numbered gutter should reserve digit space")
		ruler.showsNumbers = false
		#expect(ruler.ruleThickness <= 12, "bars-only gutter should be slim, got \(ruler.ruleThickness)")
	}

	@Test func incrementalEditorIndexAvoidsFullRebuildAfterAnEdit() throws {
		let source = (0..<20_000)
			.map { "line \($0)" }
			.joined(separator: "\n")
		let (ruler, _) = makeRuler(text: source)
		_ = try renderedColors(of: ruler)
		#expect(ruler.fullIndexRebuildCount == 1)

		let index = MarkdownLineIndex(text: source)
		ruler.setLineIndex(index)
		let edited = ("X\n" + source) as NSString
		index.applyEdit(
			in: edited,
			editedRange: NSRange(location: 0, length: 2),
			delta: 2)
		ruler.noteLineIndexChanged()
		_ = try renderedColors(of: ruler)

		#expect(ruler.fullIndexRebuildCount == 1)
		#expect(ruler.indexedLineCount == 20_001)
	}

	// MARK: Plumbing

	private func makeRuler(text: String) -> (LineNumberRulerView, NSWindow) {
		let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
		let textView = NSTextView(frame: scrollView.bounds)
		textView.string = text
		scrollView.documentView = textView
		let window = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
		window.contentView = scrollView
		let ruler = LineNumberRulerView(textView: textView)
		scrollView.verticalRulerView = ruler
		scrollView.hasVerticalRuler = true
		scrollView.rulersVisible = true
		textView.layoutManager?.ensureLayout(forCharacterRange: NSRange(location: 0, length: (text as NSString).length))
		window.orderFront(nil)
		return (ruler, window)
	}

	private func renderedColors(of ruler: LineNumberRulerView) throws -> [(r: CGFloat, g: CGFloat, b: CGFloat)] {
		let bitmap = try #require(ruler.bitmapImageRepForCachingDisplay(in: ruler.bounds))
		ruler.cacheDisplay(in: ruler.bounds, to: bitmap)
		var colors: [(CGFloat, CGFloat, CGFloat)] = []
		for y in 0..<bitmap.pixelsHigh where y % 2 == 0 {
			for x in 0..<min(bitmap.pixelsWide, 24) {
				guard let color = bitmap.colorAt(x: x, y: y) else { continue }
				colors.append((color.redComponent, color.greenComponent, color.blueComponent))
			}
		}
		return colors
	}

	private func isGreenish(_ c: (r: CGFloat, g: CGFloat, b: CGFloat)) -> Bool {
		c.g > 0.5 && c.g > c.r + 0.2 && c.g > c.b + 0.2
	}

	private func isBlueish(_ c: (r: CGFloat, g: CGFloat, b: CGFloat)) -> Bool {
		c.b > 0.5 && c.b > c.r + 0.2 && c.b > c.g + 0.2
	}

	private func isReddish(_ c: (r: CGFloat, g: CGFloat, b: CGFloat)) -> Bool {
		c.r > 0.5 && c.r > c.g + 0.2 && c.r > c.b + 0.2
	}
}
#endif
