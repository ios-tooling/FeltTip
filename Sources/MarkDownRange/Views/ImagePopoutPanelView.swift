//
//  ImagePopoutPanelView.swift
//  MarkDownRange
//

#if os(macOS)
import SwiftUI

@MainActor
struct ImagePopoutPanelView: View {
	let url: URL
	let alt: String

	@State private var intrinsicSize: CGSize?
	@State private var manualZoom: CGFloat?
	@State private var cacheToken: UUID?
	@State private var viewportSize: CGSize = .zero

	private let minimumZoom: CGFloat = 0.25
	private let maximumZoom: CGFloat = 6

	init(url: URL, alt: String, intrinsicSize: CGSize?) {
		self.url = url
		self.alt = alt
		self._intrinsicSize = State(initialValue: intrinsicSize ?? ImageDimensionCache.shared.persistedSize(for: url))
	}

	var body: some View {
		VStack(spacing: 0) {
			controls
				.padding(.horizontal, 16)
				.padding(.vertical, 12)

			Divider()

			GeometryReader { geo in
				ScrollView([.horizontal, .vertical]) {
					image
						.frame(maxWidth: .infinity, maxHeight: .infinity)
						.padding(24)
				}
				.background(Color(nsColor: .windowBackgroundColor))
				.onAppear { viewportSize = geo.size }
				.onChange(of: geo.size) { _, newValue in
					viewportSize = newValue
				}
			}
		}
		.frame(minWidth: 420, minHeight: 320)
		.onAppear(perform: beginObservingDimensions)
		.onDisappear(perform: endObservingDimensions)
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

	@ViewBuilder private var image: some View {
		if let intrinsicSize, intrinsicSize.width > 0, intrinsicSize.height > 0 {
			let zoomedSize = MarkdownImageSizing.zoomedSize(intrinsic: intrinsicSize, zoom: effectiveZoom)
			ScaleDownImage(
				url: url,
				alt: alt,
				htmlWidth: zoomedSize.width,
				htmlHeight: zoomedSize.height,
				allowUpscaling: true
			)
		} else {
			ScaleDownImage(
				url: url,
				alt: alt,
				htmlWidth: 720,
				htmlHeight: 540,
				allowUpscaling: true
			)
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

	private var contentViewportSize: CGSize {
		CGSize(
			width: max(0, viewportSize.width - 48),
			height: max(0, viewportSize.height - 48)
		)
	}

	private func beginObservingDimensions() {
		if cacheToken == nil {
			cacheToken = ImageDimensionCache.shared.subscribe {
				Task { @MainActor in
					refreshIntrinsicSize()
				}
			}
		}

		refreshIntrinsicSize()
		ImageDimensionCache.shared.prefetch(url)
	}

	private func endObservingDimensions() {
		guard let cacheToken else { return }
		ImageDimensionCache.shared.unsubscribe(cacheToken)
		self.cacheToken = nil
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

	private func refreshIntrinsicSize() {
		if let cachedSize = ImageDimensionCache.shared.size(for: url) {
			intrinsicSize = cachedSize
		}
	}
}
#endif
