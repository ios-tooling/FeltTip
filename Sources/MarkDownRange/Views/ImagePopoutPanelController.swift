//
//  ImagePopoutPanelController.swift
//  MarkDownRange
//

#if os(macOS)
import AppKit
import SwiftUI

@MainActor
final class ImagePopoutPanelController {
	static let shared = ImagePopoutPanelController()

	private var panels: [ObjectIdentifier: ActivePanel] = [:]

	func present(url: URL, alt: String, intrinsicSize: CGSize?) {
		let panel = NSPanel(
			contentRect: NSRect(origin: .zero, size: initialPanelSize(for: intrinsicSize)),
			styleMask: [.titled, .closable, .resizable, .utilityWindow],
			backing: .buffered,
			defer: false
		)
		panel.title = panelTitle(for: url, alt: alt)
		panel.minSize = NSSize(width: 420, height: 320)
		panel.isFloatingPanel = false
		panel.hidesOnDeactivate = false
		panel.isReleasedWhenClosed = false
		panel.center()
		panel.contentViewController = NSHostingController(
			rootView: ImagePopoutPanelView(url: url, alt: alt, intrinsicSize: intrinsicSize)
		)

		let identifier = ObjectIdentifier(panel)
		let activePanel = ActivePanel(panel: panel) { [weak self] in
			self?.panels.removeValue(forKey: identifier)
		}
		panel.delegate = activePanel
		panels[identifier] = activePanel

		panel.makeKeyAndOrderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
	}

	private func panelTitle(for url: URL, alt: String) -> String {
		if !alt.isEmpty {
			return alt
		}

		let lastPath = url.lastPathComponent
		return lastPath.isEmpty ? "Image" : lastPath
	}

	private func initialPanelSize(for intrinsicSize: CGSize?) -> CGSize {
		let chrome = CGSize(width: 80, height: 120)
		let baseWidth = intrinsicSize?.width ?? 960
		let baseHeight = intrinsicSize?.height ?? 720
		let width = min(max(baseWidth + chrome.width, 720), 1440)
		let height = min(max(baseHeight + chrome.height, 520), 1100)
		return CGSize(width: width, height: height)
	}
}

private final class ActivePanel: NSObject, NSWindowDelegate {
	let panel: NSPanel
	let onClose: () -> Void

	init(panel: NSPanel, onClose: @escaping () -> Void) {
		self.panel = panel
		self.onClose = onClose
	}

	func windowWillClose(_ notification: Notification) {
		onClose()
	}
}
#endif
