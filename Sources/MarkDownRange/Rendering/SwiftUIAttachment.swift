//
//  SwiftUIAttachment.swift
//  MarkDownRange
//
//  Phase 4: hosts an arbitrary SwiftUI view inline inside an NSTextView via
//  TextKit 2's NSTextAttachmentViewProvider hook. Used by the builder for
//  non-text blocks (code blocks, tables, images, etc.) and by the renderer
//  to prepend optional headers (e.g. the gallery preview's header card).
//

#if os(macOS)
@preconcurrency import AppKit
import SwiftUI

/// NSTextAttachment that builds its hosted view lazily. The builder closure
/// is @MainActor because SwiftUI views must be constructed on the main
/// thread; TextKit invokes loadView on the main thread, so this is safe.
public final class SwiftUIAttachment: NSTextAttachment, @unchecked Sendable {
	public let viewBuilder: @MainActor () -> AnyView

	/// True when this attachment should re-measure to whatever container
	/// width the renderer passes in, instead of staying at its initial
	/// fixed width. Used by tables so they grow and shrink as the text
	/// view resizes.
	public let usesContainerWidth: Bool

	/// The width used for upfront measurement. The actual rendered width may
	/// differ slightly; small differences cause text-wrap height variance but
	/// are usually within tolerance for our use cases.
	private static let measurementWidth: CGFloat = 700

	/// A single NSHostingView reused across viewport entries/exits. TextKit
	/// destroys and recreates view providers when attachments leave/re-enter
	/// the viewport, so re-creating the host each time causes a render flash.
	/// Caching here keeps the rendered content alive across re-creations.
	@MainActor fileprivate var cachedHost: NSHostingView<AnyView>?

	/// Stable fingerprint of the block this attachment renders (theme, font
	/// size, and the block's content). The renderer uses it to recognize
	/// when a rebuilt textStorage carries the same attachment in the same
	/// position, so it can patch the surrounding text in place instead of
	/// replacing the whole storage — which would tear down and re-mount the
	/// hosted views and flash the images.
	let contentKey: String?

	@MainActor
	public init(width: CGFloat? = nil, estimatedHeight: CGFloat? = nil, usesContainerWidth: Bool = false, contentKey: String? = nil, _ viewBuilder: @escaping @MainActor () -> AnyView) {
		self.viewBuilder = viewBuilder
		self.usesContainerWidth = usesContainerWidth
		self.contentKey = contentKey
		super.init(data: nil, ofType: nil)
		// Measure the view via NSHostingController to get our static bounds,
		// then assign a transparent NSImage of that size as the placeholder.
		// We deliberately do NOT pre-render the SwiftUI view to a bitmap:
		// blocks with async content (CachedURLImage / AsyncImage) snapshot
		// in their loading state, producing a wrong-looking placeholder
		// that briefly shows under the live host once it loads. Without a
		// non-nil image, AppKit draws the prohibitory "broken attachment"
		// glyph instead, which is also wrong. A transparent image at the
		// correct size avoids both — the gap before loadView is just empty
		// space, and the cached host eliminates re-entry flashes.
		let measureWidth = max(width ?? Self.measurementWidth, 1)
		let measuredHeight: CGFloat
		if let estimatedHeight {
			// Skip the synchronous NSHostingController.sizeThatFits — the
			// caller has supplied a pre-cached height for this block's size
			// class. Building 400 NSHostingControllers up front was costing
			// ~2 s per cold open of a 200-section document; reusing a single
			// measurement per size class brings that down to one measurement
			// per *kind* of block, not per *occurrence*.
			measuredHeight = max(estimatedHeight, 24)
		} else {
			let controller = NSHostingController(
				rootView: viewBuilder()
					.frame(maxWidth: measureWidth, alignment: .leading)
					.fixedSize(horizontal: false, vertical: true)
			)
			let fitting = controller.sizeThatFits(in: CGSize(width: measureWidth, height: CGFloat.greatestFiniteMagnitude))
			measuredHeight = max(fitting.height, 24)
		}
		let size = CGSize(width: measureWidth, height: measuredHeight)
		self.bounds = CGRect(origin: .zero, size: size)
		self.image = Self.transparentImage(size: size)
	}

	/// Width used for the synchronous NSHostingController measurement, when
	/// no explicit width is provided. Exposed so the size cache can key on
	/// the same width the measurement would have used.
	public static var defaultMeasurementWidth: CGFloat { Self.measurementWidth }

	public required init?(coder: NSCoder) { nil }

	/// True once TextKit has asked the view provider for a view and the
	/// hosting view has been cached. The renderer uses this to detect
	/// "attachments exist but TextKit hasn't mounted them yet" — a race
	/// between text-storage setup and the initial viewport-layout pass that
	/// otherwise leaves visible images hidden on cold open.
	@MainActor public var isMounted: Bool { cachedHost != nil }

	/// Adopt the already-mounted hosting view from a previous attachment at
	/// the same position, refreshing its rootView with this attachment's
	/// (newer) viewBuilder output. Lets a textStorage rebuild — e.g. a theme
	/// swap — keep its NSHostingViews mounted instead of letting TextKit
	/// destroy and recreate them, which otherwise produces a visible flash
	/// and a viewport-layout race where attachments stay hidden until the
	/// user scrolls.
	@MainActor public func inheritHost(from previous: SwiftUIAttachment) {
		guard let host = previous.cachedHost else { return }
		previous.cachedHost = nil
		host.rootView = AnyView(
			viewBuilder()
				.frame(maxWidth: .infinity, alignment: .leading)
				.fixedSize(horizontal: false, vertical: true)
		)
		cachedHost = host
	}

	/// Recompute bounds for a new container width. Used by the renderer
	/// after the text view's frame changes so an existing attachment can
	/// fit its new line-fragment width without rebuilding the entire
	/// textStorage.
	@MainActor public func remeasure(at width: CGFloat) {
		let measureWidth = max(width, 1)
		let controller = NSHostingController(
			rootView: viewBuilder()
				.frame(maxWidth: measureWidth, alignment: .leading)
				.fixedSize(horizontal: false, vertical: true)
		)
		let fitting = controller.sizeThatFits(in: CGSize(width: measureWidth, height: CGFloat.greatestFiniteMagnitude))
		let size = CGSize(width: measureWidth, height: max(fitting.height, 24))
		self.bounds = CGRect(origin: .zero, size: size)
		self.image = Self.transparentImage(size: size)
		// Drop the cached host so the next loadView produces a fresh
		// NSHostingView sized to the new bounds.
		self.cachedHost = nil
	}

	@MainActor private static func transparentImage(size: CGSize) -> NSImage {
		let image = NSImage(size: size)
		image.lockFocus()
		NSColor.clear.setFill()
		NSRect(origin: .zero, size: size).fill()
		image.unlockFocus()
		return image
	}

	public override func viewProvider(for parentView: NSView?, location: any NSTextLocation, textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
		let provider = SwiftUIAttachmentViewProvider(
			textAttachment: self,
			parentView: parentView,
			textLayoutManager: textContainer?.textLayoutManager,
			location: location
		)
		// We supply our own attachmentBounds via the provider, so TextKit
		// always has a non-zero size during initial layout. Tracking the
		// view's bounds dynamically caused a brief broken-attachment glyph
		// to appear before loadView ran (the view is nil at that moment).
		provider.tracksTextAttachmentViewBounds = false
		return provider
	}
}

private final class SwiftUIAttachmentViewProvider: NSTextAttachmentViewProvider {
	/// Explicit bridge for the inherited nonisolated TextKit hooks. TextKit
	/// invokes them on the main thread, and the wrapped value is only unboxed
	/// inside a checked `MainActor.assumeIsolated` scope.
	private struct MainActorAttachment: @unchecked Sendable {
		let value: SwiftUIAttachment
	}

	override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
		// Use the attachment's pre-measured bounds so TextKit always has a
		// concrete size to lay out, even before loadView runs. Without this,
		// TextKit can fall back to drawing the broken-attachment glyph.
		let attachment = textAttachment as? SwiftUIAttachment
		guard let attachment else { return .zero }
		let boxed = MainActorAttachment(value: attachment)
		return MainActor.assumeIsolated { @Sendable in boxed.value.bounds }
	}

	override func loadView() {
		let attachment = textAttachment as? SwiftUIAttachment
		guard let attachment else {
			view = MainActor.assumeIsolated { NSView() }
			return
		}
		let boxed = MainActorAttachment(value: attachment)
		let hostedView: NSView = MainActor.assumeIsolated { @Sendable in
			let attachment = boxed.value
			// TextKit re-creates view providers when an attachment re-enters the
			// viewport; reusing the same NSHostingView eliminates the render flash.
			if let cached = attachment.cachedHost {
				cached.removeFromSuperview()
				return cached
			}
			let wrapped = AnyView(
				attachment.viewBuilder()
					.frame(maxWidth: .infinity, alignment: .leading)
					.fixedSize(horizontal: false, vertical: true)
			)
			let host = NSHostingView(rootView: wrapped)
			host.translatesAutoresizingMaskIntoConstraints = false
			host.sizingOptions = [.intrinsicContentSize]
			attachment.cachedHost = host
			return host
		}
		view = hostedView
	}
}
#endif
