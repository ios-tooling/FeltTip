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

/// The system pasteboard, in the shape the paste tests need: read the current
/// string, replace it, and restore what was there when the test finishes.
///
/// Reading is macOS-only, and that is the whole point. iOS gates a read of
/// content this process did not write behind paste authorization, and an
/// xctest host has no UI to show the prompt on — the request never resolves,
/// and the suite hangs rather than fails. What the read buys is restoring the
/// user's clipboard afterwards, which matters on a Mac and means nothing on a
/// simulator, so iOS reports an empty pasteboard and skips the courtesy.
enum TestPasteboard {
	@MainActor
	static var string: String? {
		get {
			#if os(macOS)
				NSPasteboard.general.string(forType: .string)
			#else
				nil
			#endif
		}
		set {
			#if os(macOS)
				NSPasteboard.general.clearContents()
				if let newValue { NSPasteboard.general.setString(newValue, forType: .string) }
			#else
				UIPasteboard.general.string = newValue ?? ""
			#endif
		}
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
