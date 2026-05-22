//
//  PopoutableImageView.swift
//  MarkDownRange
//

import SwiftUI

/// Signal published by the content inside a `PopoutableImageView` to indicate
/// whether the image actually loaded. `true` = success, `false` = failure,
/// `nil` = still pending. Used to suppress the zoom button when there's
/// nothing meaningful to zoom into.
struct PopoutableImageLoadKey: PreferenceKey {
	static let defaultValue: Bool? = nil
	static func reduce(value: inout Bool?, nextValue: () -> Bool?) {
		if let next = nextValue() { value = next }
	}
}

@MainActor
struct PopoutableImageView<Content: View>: View {
	let url: URL
	let alt: String
	let theme: MarkdownTheme
	var htmlWidth: CGFloat?
	var htmlHeight: CGFloat?
	@ViewBuilder let content: () -> Content

	@State private var intrinsicSize: CGSize?
	@State private var isContentHovering = false
	@State private var isButtonHovering = false
	@State private var cacheToken: UUID?
	/// Image-load state reported by the wrapped content via
	/// `PopoutableImageLoadKey`. `nil` means the content hasn't reported yet
	/// (treated as "still loading" — the button stays hidden until success).
	@State private var didLoad: Bool?

	init(
		url: URL,
		alt: String,
		theme: MarkdownTheme,
		htmlWidth: CGFloat? = nil,
		htmlHeight: CGFloat? = nil,
		@ViewBuilder content: @escaping () -> Content
	) {
		self.url = url
		self.alt = alt
		self.theme = theme
		self.htmlWidth = htmlWidth
		self.htmlHeight = htmlHeight
		self.content = content
		self._intrinsicSize = State(initialValue: ImageDimensionCache.shared.persistedSize(for: url))
	}

	var body: some View {
		ZStack(alignment: .topTrailing) {
			content()
			popoutButton
		}
		.contentShape(Rectangle())
		.onPreferenceChange(PopoutableImageLoadKey.self) { didLoad = $0 }
		#if os(macOS)
		.onHover { isContentHovering = $0 }
		.onAppear(perform: beginObservingDimensions)
		.onDisappear(perform: endObservingDimensions)
		#endif
	}

	private var displayedSize: CGSize? {
		MarkdownImageSizing.displayedSize(
			intrinsic: intrinsicSize,
			htmlWidth: htmlWidth,
			htmlHeight: htmlHeight,
			isSVG: url.isSVGImage
		)
	}

	@ViewBuilder private var popoutButton: some View {
		#if os(macOS)
		// `didLoad == true` requires the wrapped content to explicitly tell us
		// it succeeded. Failed loads (and content that hasn't reported yet)
		// keep the button hidden so we don't offer to zoom a broken image.
		if didLoad == true, MarkdownImageSizing.shouldOfferPopout(for: displayedSize) {
			MarkdownAccessoryButton(
				systemImage: "arrow.up.left.and.arrow.down.right",
				theme: theme,
				label: "Pop out image"
			) {
				ImagePopoutPanelController.shared.present(
					url: url,
					alt: alt,
					intrinsicSize: intrinsicSize
				)
			}
			.padding(12)
			.opacity((isContentHovering || isButtonHovering) ? 1 : 0)
			.allowsHitTesting(isContentHovering || isButtonHovering)
			.onHover { isButtonHovering = $0 }
			.animation(.easeInOut(duration: 0.15), value: isContentHovering)
			.animation(.easeInOut(duration: 0.15), value: isButtonHovering)
			.animation(.easeInOut(duration: 0.15), value: displayedSize)
		}
		#endif
	}

	#if os(macOS)
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

	private func refreshIntrinsicSize() {
		intrinsicSize = ImageDimensionCache.shared.size(for: url)
	}
	#endif
}
