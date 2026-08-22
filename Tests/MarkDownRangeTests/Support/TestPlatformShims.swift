//
//  TestPlatformShims.swift
//  MarkDownRangeTests
//
//  The two places the editing tests touch platform chrome directly: giving the
//  web view keyboard focus, and the system pasteboard. Both differ between
//  AppKit and UIKit, and neither is what the tests are actually about.
//

import SwiftUI
import WebKit
@testable import MarkDownRange
#if os(macOS)
	import AppKit
#else
	import UIKit
#endif

extension CoordinatorBridgeHarness {
	/// Give the web view keyboard focus. Paste and the responder-chain edit
	/// routes only fire at the focused view.
	@MainActor
	func focusWebView() {
		#if os(macOS)
			webView.window?.makeFirstResponder(webView)
		#else
			webView.becomeFirstResponder()
		#endif
	}
}

/// One of WebKit's clipboard editing commands, and the `beforeinput` type it
/// fires. Copy fires none — it only writes the pasteboard.
enum ClipboardCommand: String {
	case cut, copy, paste

	var inputType: String? {
		switch self {
		case .cut: "deleteByCut"
		case .copy: nil
		case .paste: "insertFromPaste"
		}
	}
}

extension CoordinatorBridgeHarness {
	/// Drive cut/copy/paste the way the platform can.
	///
	/// macOS sends the real responder action, so these tests keep exercising
	/// WebKit's own clipboard pipeline. That matters beyond reaching the bridge:
	/// the sanitization EDITING.md describes — a multi-line plain-text flavor
	/// arriving with its newlines stripped — happens inside that pipeline, and
	/// driving the page directly would quietly stop covering it.
	///
	/// iOS can't send it. A library test bundle has no UIApplication ("this
	/// process does not have a UIApplication object and will not receive
	/// events"), so a `UIResponderStandardEditActions` send never reaches the
	/// web view and the harness waits rather than fails. There the page
	/// dispatches the same `beforeinput` the pipeline would, and the test writes
	/// the pasteboard flavors WebKit would have written — which is the contract
	/// the bridge actually implements, since it reads the clipboard host-side
	/// rather than off the event.
	@MainActor
	func clipboardCommand(_ command: ClipboardCommand) async throws {
		#if os(macOS)
			focusWebView()
			webView.perform(NSSelectorFromString("\(command.rawValue):"), with: nil)
		#else
			// Cut and copy put the selection on the clipboard themselves; here
			// the test does it, because the process can't own a pasteboard write.
			if command != .paste {
				TestPasteboard.string = try await evaluate("window.getSelection().toString()")
			}
			switch command {
			case .copy:
				// Copy mutates nothing and fires no beforeinput. Clipboard only.
				break
			case .cut:
				// Cut takes the fast path, which trusts the browser to mutate the
				// DOM and follow up with `input`. A synthetic beforeinput does
				// neither, so the edit queues and never drains — the deletion
				// simply doesn't happen. execCommand goes through WebKit's own
				// editing pipeline, so the event carries real target ranges and
				// the DOM actually changes.
				try await run("document.execCommand('cut')")
			case .paste:
				// Paste is host-driven: the page vetoes the default and posts its
				// range, and the host fills in the text. Nothing needs WebKit to
				// perform an edit, so dispatching the event is enough — and
				// execCommand('paste') is blocked without user activation anyway.
				try await run("""
					document.body.dispatchEvent(new InputEvent('beforeinput', {
					  inputType: 'insertFromPaste', bubbles: true, cancelable: true
					}));
					""")
			}
		#endif
	}
}

extension CoordinatorBridgeHarness {
	/// Drive a physical Backspace.
	///
	/// macOS sends the responder action, which is the whole point of the tests
	/// that use it: WebKit's physical-Backspace path is the one that can report
	/// a collapsed target range over an extended selection, and the bridge's
	/// fallback to the live selection exists for exactly that.
	///
	/// iOS has no UIApplication to route the action through, and sending it
	/// anyway takes the web process down — the suite then reports every test
	/// passing on the retry while xcodebuild reports the run as failed. The page
	/// performs the same edit through WebKit's own editing command instead,
	/// which arrives at the bridge as the same `deleteContentBackward`.
	@MainActor
	func deleteBackward() async throws {
		#if os(macOS)
			focusWebView()
			webView.perform(NSSelectorFromString("deleteBackward:"), with: nil)
		#else
			try await run("document.execCommand('delete')")
		#endif
	}
}

/// The clipboard the paste tests write to and read back.
///
/// macOS uses the real pasteboard, because these tests drive a real `paste:`
/// through the responder chain and WebKit's own pipeline has to find the text
/// where it expects it.
///
/// iOS can't use it at all. A library test bundle has no UIApplication, so the
/// process can't own a write: `UIPasteboard.general.string` returns nil with
/// "Operation not authorized" even for the string set a line earlier. It fails
/// fast rather than hanging, which is worse for a test — the paste path runs
/// with nothing to splice and every assertion after it is measuring the wrong
/// thing. So iOS stands MarkdownPasteboard's substitute up instead, holding the
/// text in-process where both the test and the bridge can reach it.
enum TestPasteboard {
	#if !os(macOS)
		nonisolated(unsafe) private static var held: String?
		nonisolated(unsafe) private static var heldSource: String?
	#endif

	@MainActor
	static var string: String? {
		get {
			#if os(macOS)
				NSPasteboard.general.string(forType: .string)
			#else
				held
			#endif
		}
		set {
			#if os(macOS)
				NSPasteboard.general.clearContents()
				if let newValue { NSPasteboard.general.setString(newValue, forType: .string) }
			#else
				held = newValue
				heldSource = nil
				MarkdownPasteboard.substitute = { held }
				MarkdownPasteboard.sourceSubstitute = { heldSource }
				MarkdownPasteboard.writeSourceSubstitute = { heldSource = $0 }
			#endif
		}
	}

	@MainActor
	static var source: String? {
		#if os(macOS)
			MarkdownPasteboard.source
		#else
			heldSource
		#endif
	}
}

#if os(macOS)
	typealias TestPlatformView = NSView
#else
	typealias TestPlatformView = UIView
#endif

/// Hosts a view in a real window for the duration of a test. WebKit needs a
/// window to lay out and run script reliably, and the tests that drive the
/// SwiftUI representable directly (rather than through the harness) need its
/// real lifecycle.
///
/// Instances retain themselves. On macOS `orderFront(_:)` puts the window in
/// the application's window list, so the AppKit original stayed alive after
/// its local went out of scope; a `UIWindow` gets no such treatment, and
/// callers shouldn't have to care which platform they're on.
@MainActor
final class TestWindowHost {
	private static var retained: [TestWindowHost] = []
	let view: TestPlatformView
	#if os(macOS)
		private let window: NSWindow
	#else
		private let window: UIWindow
	#endif

	convenience init<Content: View>(
		_ content: Content, size: CGSize = CGSize(width: 600, height: 400)
	) {
		#if os(macOS)
			let hosting = NSHostingView(rootView: content)
			hosting.frame = CGRect(origin: .zero, size: size)
			self.init(hosting: hosting, size: size)
		#else
			let controller = UIHostingController(rootView: content)
			controller.view.frame = CGRect(origin: .zero, size: size)
			self.init(hosting: controller.view, size: size, controller: controller)
		#endif
	}

	/// Hosts a bare view — a web view built by hand, with no SwiftUI involved.
	convenience init(view: TestPlatformView) {
		#if os(macOS)
			self.init(hosting: view, size: view.frame.size)
		#else
			let controller = UIViewController()
			controller.view.addSubview(view)
			self.init(hosting: controller.view, size: view.frame.size, controller: controller)
		#endif
	}

	#if os(macOS)
		private init(hosting: NSView, size: CGSize) {
			view = hosting
			window = NSWindow(
				contentRect: CGRect(origin: .zero, size: size),
				styleMask: [.borderless], backing: .buffered, defer: false)
			window.contentView = hosting
			window.orderFront(nil)
			Self.retained.append(self)
		}
	#else
		private init(hosting: UIView, size: CGSize, controller: UIViewController) {
			view = hosting
			window = UIWindow(frame: CGRect(origin: .zero, size: size))
			window.rootViewController = controller
			window.isHidden = false
			Self.retained.append(self)
		}
	#endif
}
