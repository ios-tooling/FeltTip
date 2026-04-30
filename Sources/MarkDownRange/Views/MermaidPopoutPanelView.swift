//
//  MermaidPopoutPanelView.swift
//  MarkDownRange
//

#if os(macOS)
import SwiftUI

@MainActor
struct MermaidPopoutPanelView: View {
	let code: String
	let mermaidTheme: String

	@State private var manualZoom: CGFloat?
	@State private var renderedSize: CGSize
	@State private var intrinsicSize: CGSize?
	@State private var hasError = false
	@State private var viewportSize: CGSize = .zero

	private let minimumZoom: CGFloat = 0.25
	private let maximumZoom: CGFloat = 4

	init(code: String, mermaidTheme: String, initialDiagramSize: CGSize?) {
		self.code = code
		self.mermaidTheme = mermaidTheme
		self._renderedSize = State(initialValue: initialDiagramSize ?? .zero)
		self._intrinsicSize = State(initialValue: initialDiagramSize)
	}

	var body: some View {
		VStack(spacing: 0) {
			controls
				.padding(.horizontal, 16)
				.padding(.vertical, 12)

			Divider()

			if hasError {
				ScrollView {
					CodeBlockView(code: code, language: "mermaid", theme: .default)
						.padding(24)
				}
			} else {
				GeometryReader { geo in
					ScrollView([.horizontal, .vertical]) {
						ZStack(alignment: .topLeading) {
							MermaidWebView(
								code: code,
								mermaidTheme: mermaidTheme,
								zoomScale: effectiveZoom,
								renderedSize: $renderedSize,
								hasError: $hasError,
								onNaturalSizeChanged: updateIntrinsicSize
							)
							.frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
						}
						.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
						.padding(24)
					}
					.background(Color(nsColor: .windowBackgroundColor))
					.onAppear { viewportSize = geo.size }
					.onChange(of: geo.size) { _, newValue in
						viewportSize = newValue
					}
				}
			}
		}
		.frame(minWidth: 520, minHeight: 380)
	}

	private var contentWidth: CGFloat {
		max(displaySize.width + 16, hasMeasuredDiagram ? 0 : 320)
	}

	private var contentHeight: CGFloat {
		max(displaySize.height + 16, hasMeasuredDiagram ? 0 : 200)
	}

	private var controls: some View {
		HStack(spacing: 12) {
			Button("Zoom Out", systemImage: "minus.magnifyingglass", action: zoomOut)
				.disabled(effectiveZoom <= minimumZoom)

			Slider(
				value: Binding(
					get: { effectiveZoom },
					set: { manualZoom = $0 }
				),
				in: minimumZoom...maximumZoom,
				step: 0.1
			)
				.frame(minWidth: 180, maxWidth: 260)
				.accessibilityLabel("Zoom")

			Button("Zoom In", systemImage: "plus.magnifyingglass", action: zoomIn)
				.disabled(effectiveZoom >= maximumZoom)

			Button("Fit", action: fitToWindow)
				.disabled(manualZoom == nil)

			Button("Actual Size", action: actualSize)
				.disabled(abs(effectiveZoom - 1) < 0.01)

			Spacer(minLength: 12)

			Text("\(Int((effectiveZoom * 100).rounded()))%")
				.monospacedDigit()
				.foregroundStyle(.secondary)
		}
	}

	private var effectiveZoom: CGFloat {
		if let manualZoom {
			return manualZoom
		}
		guard let intrinsicSize else { return 1 }
		let fitted = MarkdownImageSizing.fitScale(for: intrinsicSize, in: contentViewportSize)
		return min(maximumZoom, max(minimumZoom, fitted))
	}

	private var displaySize: CGSize {
		guard let intrinsicSize else { return renderedSize }
		return MarkdownImageSizing.zoomedSize(intrinsic: intrinsicSize, zoom: effectiveZoom)
	}

	private var hasMeasuredDiagram: Bool {
		(displaySize.width > 0 && displaySize.height > 0) ||
		(renderedSize.width > 0 && renderedSize.height > 0)
	}

	private var contentViewportSize: CGSize {
		CGSize(
			width: max(0, viewportSize.width - 48),
			height: max(0, viewportSize.height - 48)
		)
	}

	private func zoomOut() {
		manualZoom = max(minimumZoom, effectiveZoom - 0.25)
	}

	private func zoomIn() {
		manualZoom = min(maximumZoom, effectiveZoom + 0.25)
	}

	private func fitToWindow() {
		manualZoom = nil
	}

	private func actualSize() {
		manualZoom = 1
	}

	private func updateIntrinsicSize(_ size: CGSize) {
		guard size.width > 0, size.height > 0 else { return }
		intrinsicSize = size
	}
}
#endif
