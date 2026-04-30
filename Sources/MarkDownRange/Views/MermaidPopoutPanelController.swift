//
//  MermaidPopoutPanelController.swift
//  MarkDownRange
//

#if os(macOS)
import AppKit
import SwiftUI

@MainActor
final class MermaidPopoutPanelController {
	static let shared = MermaidPopoutPanelController()

	private var panels: [ObjectIdentifier: ActivePanel] = [:]

	func present(code: String, mermaidTheme: String, initialDiagramSize: CGSize?) {
		let panel = NSPanel(
			contentRect: NSRect(origin: .zero, size: initialPanelSize(for: initialDiagramSize)),
			styleMask: [.titled, .closable, .resizable, .utilityWindow],
			backing: .buffered,
			defer: false
		)
		panel.title = "Mermaid Diagram"
		panel.minSize = NSSize(width: 520, height: 380)
		panel.isFloatingPanel = false
		panel.hidesOnDeactivate = false
		panel.isReleasedWhenClosed = false
		panel.center()
		panel.contentViewController = NSHostingController(
			rootView: MermaidPopoutPanelView(
				code: code,
				mermaidTheme: mermaidTheme,
				initialDiagramSize: initialDiagramSize
			)
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

	private func initialPanelSize(for diagramSize: CGSize?) -> CGSize {
		let chrome = CGSize(width: 120, height: 150)
		let baseWidth = diagramSize?.width ?? 820
		let baseHeight = diagramSize?.height ?? 520
		let width = min(max(baseWidth + chrome.width, 760), 1440)
		let height = min(max(baseHeight + chrome.height, 560), 1100)
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
