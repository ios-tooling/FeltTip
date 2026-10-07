import JavaScriptCore
import Testing
@testable import FeltTip

/// Execute the production script with deterministic geometry and timer ordering.
/// Retain cleared callbacks too, to exercise retries already queued for dispatch.
@Suite @MainActor
struct ScrollRestoreCancellationTests {
	@Test func newerFractionCancelsDeferredPixelAndCaretRestore() throws {
		let js = try page()
		js.evaluateScript("window.__mdRestoreScrollThenCaret(1000, 12, 0); var stale = callbacks[callbacks.length - 1];")
		js.evaluateScript("document.body.scrollHeight = document.documentElement.scrollHeight = 2000; window.__mdScrollToFraction(0.8); flush(); stale();")
		#expect(js.evaluateScript("window.scrollY")?.toDouble() == 1200)
		#expect(js.evaluateScript("caretPlacements")?.toInt32() == 0)
		#expect(js.exception == nil)
	}

	@Test(arguments: ["wheel", "touchstart", "pointerdown", "keydown", "scroll"])
	func readerActivityCancelsDeferredRestore(event: String) throws {
		let js = try page()
		js.evaluateScript("window.__mdRestoreScrollThenCaret(1000, 12, 0); window.scrollY = 40; fire('\(event)');")
		js.evaluateScript("document.body.scrollHeight = document.documentElement.scrollHeight = 2000; flush();")
		#expect(js.evaluateScript("window.scrollY")?.toDouble() == 40)
		#expect(js.evaluateScript("caretPlacements")?.toInt32() == 0)
		#expect(js.exception == nil)
	}

	@Test func latestPixelRestoreWinsAndUninterruptedRestoreStillRuns() throws {
		let js = try page()
		js.evaluateScript("window.__mdRestoreScrollThenCaret(1000, 12, 0); window.__mdRestoreScrollThenCaret(800, 20, 0);")
		js.evaluateScript("document.body.scrollHeight = document.documentElement.scrollHeight = 2000; flush();")
		#expect(js.evaluateScript("window.scrollY")?.toDouble() == 800)
		#expect(js.evaluateScript("caretPlacements")?.toInt32() == 1)
		#expect(js.evaluateScript("lastCaret")?.toInt32() == 20)
		#expect(js.exception == nil)
	}

	private func page() throws -> JSContext {
		let js = try #require(JSContext())
		js.evaluateScript("""
			var callbacks = [], timers = {}, listeners = {}, caretPlacements = 0, lastCaret = null;
			var document = {
			  documentElement: {scrollHeight: 600}, body: {scrollHeight: 600, children: []},
			  querySelectorAll: function () { return []; }
			};
			var window = {
			  innerHeight: 500, scrollY: 0,
			  scrollTo: function (x, y) { this.scrollY = y; },
			  setTimeout: function (f) { var id = callbacks.push(f) - 1; timers[id] = f; return id; },
			  clearTimeout: function (id) { delete timers[id]; },
			  requestAnimationFrame: function (f) { f(); },
			  addEventListener: function (name, f) { (listeners[name] || (listeners[name] = [])).push(f); },
			  __mdPlaceCaret: function (offset) { caretPlacements++; lastCaret = offset; },
			  webkit: {messageHandlers: {mdedit: {postMessage: function () {}}}}
			};
			function fire(name) { (listeners[name] || []).forEach(function (f) { f(); }); }
			function flush() { var batch = timers; timers = {}; Object.keys(batch).forEach(function (id) { batch[id](); }); }
			""")
		js.evaluateScript(MarkdownWebView.Coordinator.scrollSyncScript)
		#expect(js.exception == nil)
		return js
	}
}
