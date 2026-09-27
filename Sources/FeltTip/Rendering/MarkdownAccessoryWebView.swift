//
//  MarkdownAccessoryWebView.swift
//  FeltTip
//
//  WKWebView doesn't offer a settable input accessory view — `inputAccessoryView`
//  is read-only on UIResponder and the web view returns its own. Overriding it
//  in a subclass is the supported way to put a formatting row above the keyboard.
//

#if os(iOS)
import SwiftUI
import WebKit

final class MarkdownAccessoryWebView: WKWebView {
	/// Retained separately from the view it vends: a UIHostingController whose
	/// only strong reference is its own view gets deallocated, taking the
	/// SwiftUI state with it.
	private var accessoryHost: UIViewController?

	override var inputAccessoryView: UIView? { accessoryHost?.view }

	/// Install the formatting row. Passing nil removes it — the web view then
	/// falls back to whatever the system would show.
	@MainActor
	func setFormattingBar<Bar: View>(_ bar: Bar?) {
		guard let bar else {
			accessoryHost = nil
			reloadInputViews()
			return
		}
		let controller = UIHostingController(rootView: bar)
		controller.view.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 44)
		controller.view.autoresizingMask = [.flexibleWidth]
		// The accessory sits over the keyboard; its own backing must not paint
		// an opaque rectangle behind the bar material.
		controller.view.backgroundColor = .clear
		accessoryHost = controller
		reloadInputViews()
	}
}
#endif
